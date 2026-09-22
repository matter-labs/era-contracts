// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {ICommittedUpgrade} from "./ICommittedUpgrade.sol";
import {ICTMRelease} from "./ICTMRelease.sol";
import {ICTMTransition} from "./ICTMTransition.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {TransitionDerivationLib} from "../libraries/TransitionDerivationLib.sol";
import {L2PlanLib} from "../libraries/L2PlanLib.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {SemVer} from "../../../common/libraries/SemVer.sol";
import {MAX_ALLOWED_MINOR_VERSION_DELTA} from "../../../common/Config.sol";
import {
    NewProtocolMajorVersionNotZero,
    PreviousProtocolMajorVersionNotZero,
    ProtocolVersionMinorDeltaTooBig,
    ProtocolVersionTooSmall
} from "../../ZkSyncUpgradeErrors.sol";
import {
    PatchCannotCarryL2Upgrade,
    PatchChangesL2GenesisState,
    SameReleaseTransitionHasPayload,
    TransitionDeadlineBeforeUpgrade,
    TransitionDeadlineZero,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {L2UpgradePlan, TransitionManifest, ReleaseDiff} from "../RegistryTypes.sol";
import {IDefaultUpgrade} from "../../IDefaultUpgrade.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";

/// @notice Storage-backed, write-once transition between two CTM releases.
/// @dev The facet cuts and table-derived L2 deployments are NOT part of the manifest: they are
///      DERIVED from the `(fromRelease, newRelease)` pair at initialization (see
///      {TransitionDerivationLib}) and stored. Transition and release state cannot diverge because
///      the delta is a pure function of the two pinned releases.
/// @dev What IS authored: the version edge, upgrade engine, schedule and the L2 plan's authored
///      input (the delegate's and any extra bytecode, the composer). The verifier is NOT
///      authored here: it is part of the installed
///      chain state and therefore lives on the release, so it converges by the same mechanism as
///      facet routing. The final L2 plan is CONSTRUCTED from the target release's bytecode table
///      and the authored input ({L2PlanLib.build}); the authored input is REVIEWED data
///      (L1 cannot verify L2 execution effects), so the on-chain convergence guarantee
///      covers L1 state only.
contract CTMTransition is ICTMTransition {
    /// @dev THE manifest, stored as its own ABI encoding — see {CTMRelease} for why the struct is
    ///      not transcribed into structured storage.
    bytes internal encodedManifest;

    // Derived at initialization from (fromRelease, newRelease) — never authored, and stored as
    // ready-to-execute cuts the chain applies verbatim (no re-diffing at execution).
    Diamond.FacetCut[] internal derivedFacetCuts;
    /// @dev The FINAL L2 plan, constructed at initialization and stored as its ABI encoding (same
    ///      reasoning as `encodedManifest`: the legacy codegen pipeline cannot copy a struct array
    ///      with dynamic members into storage).
    bytes internal encodedL2Plan;

    /// @notice Pins the manifest and DERIVES the delta. No state-mutating function exists on this
    ///         contract: everything is written once, at construction.
    constructor(TransitionManifest memory _manifest) {
        // `fromRelease` is MANDATORY: every transition departs from a real, pinned release.
        // Bootstrapping a pre-registry CTM is one-time migration code, never an accommodation
        // here; see the Bootstrap section of {docs/registry-driven-upgrades.md}.
        if (
            _manifest.fromRelease == address(0) ||
            _manifest.newRelease == address(0) ||
            _manifest.upgradeEngine == address(0)
        ) {
            revert ZeroAddress();
        }
        // A transition only ever moves the version forward — the same rule chains enforce at
        // execution and the CTM enforces in `setNewVersionUpgrade`.
        if (_manifest.newProtocolVersion <= _manifest.oldProtocolVersion) {
            revert ProtocolVersionTooSmall(_manifest.oldProtocolVersion, _manifest.newProtocolVersion);
        }
        // A zero deadline expires the departing version the moment the edge is committed, which
        // stops every chain still on it from committing batches before any of them can upgrade.
        // The relative check below cannot catch it: a zeroed schedule satisfies `0 >= 0`.
        // `upgradeTimestamp` has no such lower bound — zero there legitimately means chains may
        // upgrade as soon as the edge is committed. Only the ZERO deadline is refused: any nonzero
        // value passes, including one already in the past, which disables the departing version
        // immediately. That is permitted — an incident may call for it — merely discouraged; zero
        // is refused because it is far likelier a defaulted field than a decision.
        if (_manifest.oldProtocolVersionDeadline == 0) {
            revert TransitionDeadlineZero();
        }
        // The old version must stay usable at least until chains are allowed to upgrade,
        // otherwise the schedule disables the old protocol before the new one is reachable.
        if (_manifest.oldProtocolVersionDeadline < _manifest.upgradeTimestamp) {
            revert TransitionDeadlineBeforeUpgrade(_manifest.oldProtocolVersionDeadline, _manifest.upgradeTimestamp);
        }

        // The engine's code existence is checked by `validate()` on the execution paths, not
        // here — see {CoreRegistry}. Both release EDGES are validated, though: the
        // delta below is derived from their manifests, so a malformed edge would silently
        // produce a malformed cut.
        // WHICH releases these are is governance's decision, established by review: the
        // executor's release-edge check ties `fromRelease` to the CTM's live `currentRelease`,
        // and `newRelease` is what the same operation then installs.
        ICTMRelease(_manifest.newRelease).validate();
        ICTMRelease(_manifest.fromRelease).validate();

        bool isPatch;
        {
            // Patch component deliberately ignored: this check is about the major.minor edge.
            // slither-disable-next-line unused-return
            (uint32 oldMajor, uint32 oldMinor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_manifest.oldProtocolVersion));
            // slither-disable-next-line unused-return
            (uint32 newMajor, uint32 newMinor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_manifest.newProtocolVersion));
            // A SemVer PATCH edge. It may name a NEW release: a release is the immutable snapshot
            // of the intended contracts, and replacing a verifier or a facet in that snapshot is
            // not by itself a change of chain-visible L2 state. What a patch may not do is carry
            // an L2 upgrade transaction — see the patch checks after the plan is combined.
            isPatch = oldMajor == newMajor && oldMinor == newMinor;
            // The same version-shape rules `BaseZkSyncUpgrade._setNewProtocolVersion` applies per
            // chain. Without them a transition pins fine and `applyCTMUpgrade` bumps the CTM, after
            // which EVERY chain upgrade reverts and only break-glass can recover.
            // Watch out: there are plans to move ZKsync OS to major 1 to distinguish it from Era.
            // When that lands, this pair of checks and `_setNewProtocolVersion` change together.
            if (oldMajor != 0) {
                revert PreviousProtocolMajorVersionNotZero();
            }
            if (newMajor != 0) {
                revert NewProtocolMajorVersionNotZero();
            }
            // Safe: majors are both zero and the packed new version is strictly greater, so the
            // minor cannot have decreased.
            uint256 minorDelta = newMinor - oldMinor;
            if (minorDelta > MAX_ALLOWED_MINOR_VERSION_DELTA) {
                revert ProtocolVersionMinorDeltaTooBig(MAX_ALLOWED_MINOR_VERSION_DELTA, minorDelta);
            }
        }
        // The FINAL plan: the target release's table-derived set (empty for a same-release pair by
        // identity), then the authored delegate and extras at their bytecode-derived addresses,
        // with the factory dependencies of everything installed — constructed, never authored.
        L2UpgradePlan memory l2Plan = L2PlanLib.build(
            TransitionDerivationLib.deriveL2Deployments(
                ICTMRelease(_manifest.fromRelease),
                ICTMRelease(_manifest.newRelease)
            ),
            _manifest.l2Plan
        );
        // A delegate is itself deployed, so a plan has an L2 side exactly when it deploys.
        bool hasL2Side = l2Plan.deployments.length != 0;
        // A same-release transition is schedule-only: the derived facet/deployment delta is
        // empty by construction, and it must not carry an authored L2 payload either.
        if (_manifest.fromRelease == _manifest.newRelease && hasL2Side) {
            revert SameReleaseTransitionHasPayload();
        }
        // A PATCH edge may move L1 code (the verifier, facets, CTM-domain proxy rows) but never
        // the chains' L2 side: `BaseZkSyncUpgrade._setL2SystemContractUpgrade` refuses an L2
        // protocol upgrade transaction on a patch (`PatchCantSetUpgradeTxn`), and a patch
        // deliberately does NOT require an earlier L2 upgrade to be finalized first — a pending
        // one must survive the patch untouched. Refused HERE, before governance can commit a
        // transition that would bump the CTM and then revert on every chain.
        if (isPatch) {
            if (hasL2Side) {
                revert PatchCannotCarryL2Upgrade();
            }
            // An empty DERIVED deployment list is not enough on its own: it only proves the two
            // L2 bytecode tables agree. The rest of the release's L2/genesis description — the
            // force-deployment blob and the genesis batch a new chain starts from, and the VM the
            // pinned DiamondInit selects — is never executed on an existing chain, so a patch
            // changing it would leave chains created after the patch describing a different L2
            // state from the ones that took it.
            _requirePatchKeepsL2State(ICTMRelease(_manifest.fromRelease), ICTMRelease(_manifest.newRelease));
        }

        encodedManifest = abi.encode(_manifest);
        encodedL2Plan = abi.encode(l2Plan);

        // Derive the L1 delta from the release pair and freeze it as final diamond cuts.
        Diamond.FacetCut[] memory facetCutsMemory = TransitionDerivationLib.deriveFacetCuts(
            ICTMRelease(_manifest.fromRelease),
            ICTMRelease(_manifest.newRelease)
        );
        uint256 length = facetCutsMemory.length;
        for (uint256 i = 0; i < length; ++i) {
            derivedFacetCuts.push(facetCutsMemory[i]);
        }
    }

    /// @dev The L2/genesis description a patch must carry over unchanged (see the constructor).
    ///      Compared by value, not by release identity — the point of allowing a patch to name a
    ///      new release is that the snapshot may differ in its L1 members.
    function _requirePatchKeepsL2State(ICTMRelease _fromRelease, ICTMRelease _newRelease) private view {
        if (address(_fromRelease) == address(_newRelease)) {
            return;
        }
        if (
            keccak256(abi.encode(_fromRelease.l2BytecodeInfos())) !=
                keccak256(abi.encode(_newRelease.l2BytecodeInfos())) ||
            keccak256(_fromRelease.l2SystemProxyBytecodeInfo()) != keccak256(_newRelease.l2SystemProxyBytecodeInfo()) ||
            keccak256(_fromRelease.fixedForceDeploymentsData()) != keccak256(_newRelease.fixedForceDeploymentsData())
        ) {
            revert PatchChangesL2GenesisState();
        }
        // slither-disable-next-line unused-return
        (, bytes32 fromBatchHash, uint64 fromIndex) = _fromRelease.genesisParams();
        // slither-disable-next-line unused-return
        (, bytes32 newBatchHash, uint64 newIndex) = _newRelease.genesisParams();
        if (fromBatchHash != newBatchHash || fromIndex != newIndex) {
            revert PatchChangesL2GenesisState();
        }
    }

    /// @inheritdoc ICTMTransition
    function releaseDiff() external view returns (ReleaseDiff memory diff) {
        TransitionManifest memory m = getManifest();
        if (m.fromRelease == m.newRelease) {
            return diff;
        }
        ICTMRelease from = ICTMRelease(m.fromRelease);
        ICTMRelease to = ICTMRelease(m.newRelease);
        diff.diamondInit = from.diamondInit() != to.diamondInit();
        diff.verifier = from.verifier() != to.verifier();
        {
            (address fromGenesisUpgrade, bytes32 fromBatchHash, uint64 fromIndex) = from.genesisParams();
            (address toGenesisUpgrade, bytes32 toBatchHash, uint64 toIndex) = to.genesisParams();
            diff.genesisUpgrade = fromGenesisUpgrade != toGenesisUpgrade;
            diff.genesisBatch = fromBatchHash != toBatchHash || fromIndex != toIndex;
        }
        diff.genesisFacets = keccak256(abi.encode(from.genesisFacets())) != keccak256(abi.encode(to.genesisFacets()));
        diff.l2BytecodeInfos =
            keccak256(abi.encode(from.l2BytecodeInfos())) != keccak256(abi.encode(to.l2BytecodeInfos()));
        diff.l2SystemProxyBytecodeInfo =
            keccak256(from.l2SystemProxyBytecodeInfo()) != keccak256(to.l2SystemProxyBytecodeInfo());
        diff.fixedForceDeploymentsData =
            keccak256(from.fixedForceDeploymentsData()) != keccak256(to.fixedForceDeploymentsData());
    }

    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment governance compares
    ///         against the audited manifest. Computed from the stored encoding, not stored
    ///         separately: no contract reads it, and a second copy could only ever agree.
    function manifestHash() external view returns (bytes32) {
        return keccak256(encodedManifest);
    }

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() public view returns (TransitionManifest memory) {
        return abi.decode(encodedManifest, (TransitionManifest));
    }

    function oldProtocolVersion() external view returns (uint256) {
        return getManifest().oldProtocolVersion;
    }

    function newProtocolVersion() external view returns (uint256) {
        return getManifest().newProtocolVersion;
    }

    function fromRelease() external view returns (address) {
        return getManifest().fromRelease;
    }

    function newRelease() external view returns (address) {
        return getManifest().newRelease;
    }

    function upgradeEngine() external view returns (address) {
        return getManifest().upgradeEngine;
    }

    function oldProtocolVersionDeadline() external view returns (uint256) {
        return getManifest().oldProtocolVersionDeadline;
    }

    function upgradeTimestamp() external view returns (uint256) {
        return getManifest().upgradeTimestamp;
    }

    /// @inheritdoc ICommittedUpgrade
    function upgradeTarget() external view returns (uint256, uint256, address) {
        TransitionManifest memory m = getManifest();
        return (m.newProtocolVersion, m.upgradeTimestamp, m.newRelease);
    }

    function facetCuts() external view returns (Diamond.FacetCut[] memory) {
        return derivedFacetCuts;
    }

    /// @inheritdoc ICommittedUpgrade
    /// @dev Exactly as constructed at initialization.
    function l2Plan() external view returns (L2UpgradePlan memory) {
        return abi.decode(encodedL2Plan, (L2UpgradePlan));
    }

    /// @inheritdoc ICTMTransition
    function l2UpgradeTx(address _bridgehub, uint256 _chainId) external view returns (L2CanonicalTransaction memory) {
        return IDefaultUpgrade(getManifest().upgradeEngine).l2UpgradeTx(address(this), _bridgehub, _chainId);
    }

    /// @inheritdoc ICTMTransition
    /// @dev THE enumeration of what this transition names itself: the upgrade engine and the
    ///      delegate composer (version-specific CODE in place of authored calldata) when the plan
    ///      names one. The two release edges are objects with check surfaces of their own.
    function validate() external view {
        TransitionManifest memory m = getManifest();
        ICTMRelease(m.newRelease).validate();
        ICTMRelease(m.fromRelease).validate();
        ObjectAnchorLib.requireCode(m.upgradeEngine);
        if (m.l2Plan.delegateComposer != address(0)) {
            ObjectAnchorLib.requireCode(m.l2Plan.delegateComposer);
        }
    }
}
