// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ManifestStorage} from "./ManifestStorage.sol";
import {ICommittedUpgrade} from "./ICommittedUpgrade.sol";
import {ICTMRelease} from "./ICTMRelease.sol";
import {ICTMTransition} from "./ICTMTransition.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {TransitionDerivationLib} from "../libraries/TransitionDerivationLib.sol";
import {L2PlanLib} from "../libraries/L2PlanLib.sol";
import {VersionEdgeLib} from "../libraries/VersionEdgeLib.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {L1OnlyEdgeChangesL2State, ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {L2UpgradePlan, TransitionManifest, ReleaseDiff} from "../RegistryTypes.sol";
import {IDefaultUpgrade} from "../../IDefaultUpgrade.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";

/// @notice Storage-backed, write-once transition between two CTM releases.
/// @dev The facet cuts and table-derived L2 deployments are NOT part of the manifest: they are
///      DERIVED from the `(fromRelease, newRelease)` pair at initialization (see
///      {TransitionDerivationLib}) and stored. Transition and release state cannot diverge because
///      the delta is a pure function of the two pinned releases.
/// @dev What IS authored: the upgrade engine, schedule and the L2 plan's authored input (the
///      delegate's and any extra bytecode, the composer). The version edge is NOT: a release IS one
///      protocol version, so the edge is the two releases' own versions. Nor is the verifier: it
///      is part of the installed chain state and therefore lives on the release, so it converges
///      by the same mechanism as facet routing. The final L2 plan is CONSTRUCTED from the target
///      release's bytecode table and the authored input ({L2PlanLib.build}); the authored input is
///      REVIEWED data (L1 cannot verify L2 execution effects), so the on-chain convergence guarantee
///      covers L1 state only.
contract CTMTransition is ICTMTransition, ManifestStorage {
    // Derived at initialization from (fromRelease, newRelease) — never authored, and stored as
    // ready-to-execute cuts the chain applies verbatim (no re-diffing at execution).
    Diamond.FacetCut[] internal derivedFacetCuts;
    /// @dev The FINAL L2 plan, constructed at initialization and stored as its ABI encoding (same
    ///      reasoning as `encodedManifest`: the legacy codegen pipeline cannot copy a struct array
    ///      with dynamic members into storage).
    bytes internal encodedL2Plan;
    /// @dev The version edge, read off the two releases at construction and kept here so a chain's
    ///      upgrade reads it without decoding either release.
    uint256 internal derivedOldProtocolVersion;
    uint256 internal derivedNewProtocolVersion;

    /// @notice Pins the manifest and DERIVES the delta. No state-mutating function exists on this
    ///         contract: everything is written once, at construction.
    constructor(TransitionManifest memory _manifest) ManifestStorage(abi.encode(_manifest)) {
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
        uint256 oldVersion = ICTMRelease(_manifest.fromRelease).protocolVersion();
        uint256 newVersion = ICTMRelease(_manifest.newRelease).protocolVersion();
        derivedOldProtocolVersion = oldVersion;
        derivedNewProtocolVersion = newVersion;

        // The engine's code existence is checked by `validate()` on the execution paths, not
        // here — see {CoreTransition}. Both release EDGES are validated, though: the
        // delta below is derived from their manifests, so a malformed edge would silently
        // produce a malformed cut.
        // WHICH releases these are is governance's decision, established by review: the
        // executor's release-edge check ties `fromRelease` to the CTM's live `currentRelease`,
        // and `newRelease` is what the same operation then installs.
        ICTMRelease(_manifest.newRelease).validate();
        ICTMRelease(_manifest.fromRelease).validate();

        // The FINAL plan: the target release's table-derived set, then the authored delegate and
        // extras at their bytecode-derived addresses, with the factory dependencies of everything
        // installed — constructed, never authored.
        L2UpgradePlan memory derivedPlan = L2PlanLib.build(
            TransitionDerivationLib.deriveL2Deployments(
                ICTMRelease(_manifest.fromRelease),
                ICTMRelease(_manifest.newRelease)
            ),
            _manifest.l2Plan
        );
        // Since the edge IS the two releases' versions, the version check is also what refuses
        // the same release on both edges. A delegate is itself deployed, so a plan has an L2 side
        // exactly when it deploys.
        bool hasL2Side = derivedPlan.deployments.length != 0;
        VersionEdgeLib.requireValidEdge({
            _oldVersion: oldVersion,
            _newVersion: newVersion,
            _oldVersionDeadline: _manifest.oldProtocolVersionDeadline,
            _upgradeTimestamp: _manifest.upgradeTimestamp,
            _hasL2Side: hasL2Side
        });
        // An edge without an L2 side (every patch among them) may name a NEW release — replacing
        // a verifier or a facet in the snapshot is not by itself a change of chain-visible L2
        // state — but must leave the release's L2 description as it was.
        if (!hasL2Side) {
            // An empty DERIVED deployment list is not enough on its own: it only proves the two
            // L2 bytecode tables agree. The rest of the release's L2/genesis description — the
            // force-deployment blob, the genesis upgrade and the genesis batch a new chain starts
            // from — is never executed on an existing chain, so changing it on an edge that sends
            // existing chains nothing would leave chains created after the edge describing a
            // different L2 state from the ones that crossed it.
            _requireL2StateKept(ICTMRelease(_manifest.fromRelease), ICTMRelease(_manifest.newRelease));
        }

        encodedL2Plan = abi.encode(derivedPlan);

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

    /// @dev The L2/genesis description an edge without an L2 side must carry over unchanged (see
    ///      the constructor). Compared by value: such an edge names a release of its own, whose
    ///      snapshot may differ from the departing one in its L1 members only.
    function _requireL2StateKept(ICTMRelease _fromRelease, ICTMRelease _newRelease) private view {
        if (
            keccak256(abi.encode(_fromRelease.l2BytecodeInfos())) !=
                keccak256(abi.encode(_newRelease.l2BytecodeInfos())) ||
            keccak256(_fromRelease.l2SystemProxyBytecodeInfo()) != keccak256(_newRelease.l2SystemProxyBytecodeInfo()) ||
            keccak256(_fromRelease.fixedForceDeploymentsData()) != keccak256(_newRelease.fixedForceDeploymentsData())
        ) {
            revert L1OnlyEdgeChangesL2State();
        }
        // The genesis upgrade counts as L2 state: it composes a new chain's L2 genesis transaction.
        (address fromGenesisUpgrade, bytes32 fromBatchHash, uint64 fromIndex) = _fromRelease.genesisParams();
        (address newGenesisUpgrade, bytes32 newBatchHash, uint64 newIndex) = _newRelease.genesisParams();
        if (fromGenesisUpgrade != newGenesisUpgrade || fromBatchHash != newBatchHash || fromIndex != newIndex) {
            revert L1OnlyEdgeChangesL2State();
        }
    }

    /// @inheritdoc ICTMTransition
    function releaseDiff() external view returns (ReleaseDiff memory diff) {
        TransitionManifest memory m = getManifest();
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

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() public view returns (TransitionManifest memory) {
        return abi.decode(encodedManifest, (TransitionManifest));
    }

    /// @inheritdoc ICTMTransition
    function oldProtocolVersion() external view returns (uint256) {
        return derivedOldProtocolVersion;
    }

    /// @inheritdoc ICTMTransition
    function newProtocolVersion() external view returns (uint256) {
        return derivedNewProtocolVersion;
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
        return (derivedNewProtocolVersion, m.upgradeTimestamp, m.newRelease);
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
