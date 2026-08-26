// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {ICTMRelease} from "./ICTMRelease.sol";
import {ICTMTransition} from "./ICTMTransition.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {TransitionDeltaLib} from "../libraries/TransitionDeltaLib.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {SemVer} from "../../../common/libraries/SemVer.sol";
import {MAX_ALLOWED_MINOR_VERSION_DELTA, MAX_NEW_FACTORY_DEPS} from "../../../common/Config.sol";
import {
    NewProtocolMajorVersionNotZero,
    PreviousProtocolMajorVersionNotZero,
    ProtocolVersionMinorDeltaTooBig,
    ProtocolVersionTooSmall
} from "../../ZkSyncUpgradeErrors.sol";
import {
    MalformedL2UpgradePlan,
    PatchMustReuseRelease,
    RegistryUnknownKey,
    SameReleaseTransitionHasPayload,
    TransitionDeadlineBeforeUpgrade,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {L2UpgradePlan, TransitionManifest} from "../RegistryTypes.sol";

/// @notice Storage-backed, write-once transition between two CTM releases.
/// @dev The facet cuts and base-system hash changes are NOT part of the manifest: they are
///      DERIVED from the `(fromRelease, newRelease)` pair at initialization (see
///      {TransitionDeltaLib}) and stored. Transition and release state cannot diverge because
///      the delta is a pure function of the two pinned releases.
/// @dev What IS authored: the version edge, upgrade engine, schedule and the L2 plan — each either
///      derived-checked or codehash-pinned inline. The verifier is NOT authored here: it is part of
///      the installed chain state and therefore lives on the release, so it converges by the same
///      mechanism as facet routing. The L2 plan is reviewed-and-pinned data (L1 cannot verify L2
///      execution effects); the on-chain convergence guarantee covers L1 state only.
contract CTMTransition is ICTMTransition {

    /// @notice `keccak256(abi.encode(manifest))`. No contract reads this — it is a review aid, a
    ///         single value to compare against the audited manifest. Provenance is the codehash.
    bytes32 public manifestHash;

    /// @dev THE manifest, stored as its own ABI encoding — see {CTMRelease} for why the struct is
    ///      not transcribed into structured storage.
    bytes internal encodedManifest;

    // Derived at initialization from (fromRelease, newRelease) — never authored, and stored as
    // ready-to-execute cuts the chain applies verbatim (no re-diffing at execution).
    Diamond.FacetCut[] internal derivedFacetCuts;
    bytes32 internal derivedBootloaderChange;
    bytes32 internal derivedDefaultAccountChange;
    bytes32 internal derivedEvmEmulatorChange;

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
        // The old version must stay usable at least until chains are allowed to upgrade,
        // otherwise the schedule disables the old protocol before the new one is reachable.
        if (_manifest.oldProtocolVersionDeadline < _manifest.upgradeTimestamp) {
            revert TransitionDeadlineBeforeUpgrade(_manifest.oldProtocolVersionDeadline, _manifest.upgradeTimestamp);
        }

        // The upgrade engine's pin is checked by `validate()` against live code, not here — see
        // {CoreRegistry}. Both release EDGES are validated, though: the delta below is derived
        // from their manifests, so a malformed edge would silently produce a malformed cut.
        // RELEASE PROVENANCE is still deliberately NOT checked here: the
        // attestation that both edges are genuine write-once CTMRelease instances comes from the
        // CTM itself — its canonical `releaseCodehash` is enforced in `_storeCurrentRelease`, which
        // every pinned release (bootstrap and every transition target) passes through, and the
        // executor's release edge check ties `fromRelease` to that same pinned `currentRelease`.
        ICTMRelease(_manifest.newRelease).validate();
        ICTMRelease(_manifest.fromRelease).validate();

        // A SemVer patch bump changes no chain state by definition, so it must reuse the
        // departing release.
        {
            // Patch component deliberately ignored: this check is about the major.minor edge.
            // slither-disable-next-line unused-return
            (uint32 oldMajor, uint32 oldMinor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_manifest.oldProtocolVersion));
            // slither-disable-next-line unused-return
            (uint32 newMajor, uint32 newMinor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_manifest.newProtocolVersion));
            if (oldMajor == newMajor && oldMinor == newMinor && _manifest.fromRelease != _manifest.newRelease) {
                revert PatchMustReuseRelease(_manifest.fromRelease, _manifest.newRelease);
            }
            // The same version-shape rules `BaseZkSyncUpgrade._setNewProtocolVersion` applies per
            // chain. Without them a transition pins fine and `applyCTMUpgrade` bumps the CTM, after
            // which EVERY chain upgrade reverts and only break-glass can recover.
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
        // L2 plan shape: committed data must be data the composed transaction actually EXECUTES.
        // `L2ComplexUpgrader.forceDeployAndUpgradeUniversal` unconditionally ends with the
        // delegatecall, so a nonempty plan REQUIRES a delegate target (a deployments-only plan
        // would initialize here but revert on L2 forever); a delegate calldata without a target,
        // or factory deps without any L2 side, would be silently dead payload — refuse all of it.
        bool hasL2Side = _manifest.l2Plan.deployments.length != 0 || _manifest.l2Plan.delegateTo != address(0);
        if (
            (_manifest.l2Plan.deployments.length != 0 && _manifest.l2Plan.delegateTo == address(0)) ||
            (_manifest.l2Plan.delegateCalldata.length != 0 && _manifest.l2Plan.delegateTo == address(0)) ||
            (_manifest.l2Plan.factoryDepHashes.length != 0 && !hasL2Side)
        ) {
            revert MalformedL2UpgradePlan();
        }
        // The same cap `BaseZkSyncUpgrade._verifyFactoryDeps` applies at execution. Without it here
        // an oversized plan would initialize and `applyCTMUpgrade` would bump the CTM's version,
        // after which EVERY chain upgrade reverts — stranding chains on a committed but
        // unexecutable transition.
        if (_manifest.l2Plan.factoryDepHashes.length > MAX_NEW_FACTORY_DEPS) {
            revert MalformedL2UpgradePlan();
        }
        // A same-release transition is schedule-only: the derived facet/hash delta is
        // empty by construction, and it must not carry an L2 payload either.
        if (_manifest.fromRelease == _manifest.newRelease && hasL2Side) {
            revert SameReleaseTransitionHasPayload();
        }

        encodedManifest = abi.encode(_manifest);
        manifestHash = keccak256(encodedManifest);

        // Derive the L1 delta from the release pair and freeze it as final diamond cuts.
        Diamond.FacetCut[] memory facetCutsMemory = TransitionDeltaLib.deriveFacetCuts(
            ICTMRelease(_manifest.fromRelease),
            ICTMRelease(_manifest.newRelease)
        );
        uint256 length = facetCutsMemory.length;
        for (uint256 i = 0; i < length; ++i) {
            derivedFacetCuts.push(facetCutsMemory[i]);
        }
        (derivedBootloaderChange, derivedDefaultAccountChange, derivedEvmEmulatorChange) = TransitionDeltaLib
            .deriveHashChanges(ICTMRelease(_manifest.fromRelease), ICTMRelease(_manifest.newRelease));
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

    function facetCuts() external view returns (Diamond.FacetCut[] memory) {
        return derivedFacetCuts;
    }

    function baseSystemContractHashChanges() external view returns (bytes32, bytes32, bytes32) {
        return (derivedBootloaderChange, derivedDefaultAccountChange, derivedEvmEmulatorChange);
    }

    function l2Plan() external view returns (L2UpgradePlan memory) {
        return getManifest().l2Plan;
    }

    function validate() external view {
        TransitionManifest memory m = getManifest();
        ICTMRelease(m.newRelease).validate();
        ICTMRelease(m.fromRelease).validate();
        _requirePin(m.upgradeEngine, m.upgradeEngineCodehash);
    }

    function verifyAll() external view returns (bool) {
        TransitionManifest memory m = getManifest();
        if (!ICTMRelease(m.newRelease).verifyAll() || !ICTMRelease(m.fromRelease).verifyAll()) {
            return false;
        }
        return CodehashPinLib.pinHolds(m.upgradeEngine, m.upgradeEngineCodehash);
    }

    function _requirePin(address _target, bytes32 _expectedCodehash) private view {
        CodehashPinLib.requirePin(_target, _expectedCodehash);
    }
}
