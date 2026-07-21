// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {ICTMRelease} from "./ICTMRelease.sol";
import {ICTMTransition, L2UpgradePlan} from "./ICTMTransition.sol";
import {CodehashPinLib} from "./CodehashPinLib.sol";
import {TransitionDeltaLib} from "./TransitionDeltaLib.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {SemVer} from "../../common/libraries/SemVer.sol";
import {ProtocolVersionTooSmall} from "../ZkSyncUpgradeErrors.sol";
import {
    MalformedL2UpgradePlan,
    PatchMustReuseRelease,
    RegistryAlreadyInitialized,
    RegistryUnknownKey,
    SameReleaseTransitionHasPayload,
    TransitionDeadlineBeforeUpgrade,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";

/// @notice Storage-backed, write-once transition between two CTM releases.
/// @dev The facet cuts and base-system hash changes are NOT part of the manifest: they are
///      DERIVED from the `(fromRelease, newRelease)` pair at initialization (see
///      {TransitionDeltaLib}) and stored. Transition and release state cannot diverge because
///      the delta is a pure function of the two pinned releases.
/// @dev What IS authored: the version edge, verifier, upgrade engine, schedule and the L2 plan —
///      each either derived-checked or codehash-pinned inline. The L2 plan is reviewed-and-pinned
///      data (L1 cannot verify L2 execution effects); the on-chain convergence guarantee covers
///      L1 diamond routing and base-system hashes only.
contract CTMTransition is ICTMTransition {
    // solhint-disable-next-line gas-struct-packing
    struct TransitionManifest {
        uint256 oldProtocolVersion;
        uint256 newProtocolVersion;
        address verifier;
        bytes32 verifierCodehash;
        address fromRelease;
        address newRelease;
        address upgradeEngine;
        bytes32 upgradeEngineCodehash;
        uint256 oldProtocolVersionDeadline;
        uint256 upgradeTimestamp;
        L2UpgradePlan l2Plan;
    }

    bool public initialized;
    bytes32 public manifestHash;

    uint256 internal transitionOldProtocolVersion;
    uint256 internal transitionNewProtocolVersion;
    address internal transitionVerifier;
    bytes32 internal verifierCodehash;
    address internal transitionFromRelease;
    address internal transitionNewRelease;
    address internal transitionUpgradeEngine;
    bytes32 internal upgradeEngineCodehash;
    uint256 internal transitionOldProtocolVersionDeadline;
    uint256 internal transitionUpgradeTimestamp;
    L2UpgradePlan internal plan;

    // Derived at initialization from (fromRelease, newRelease) — never authored, and stored as
    // ready-to-execute cuts the chain applies verbatim (no re-diffing at execution).
    Diamond.FacetCut[] internal derivedFacetCuts;
    bytes32 internal derivedBootloaderChange;
    bytes32 internal derivedDefaultAccountChange;
    bytes32 internal derivedEvmEmulatorChange;

    function initialize(TransitionManifest calldata _manifest) external {
        if (initialized) {
            revert RegistryAlreadyInitialized();
        }
        // `fromRelease` is MANDATORY: every transition departs from a real, pinned release.
        // Pre-registry migration (v31 -> v32) is one-time migration code in the legacy upgrade
        // scripts — it installs `currentRelease` so that every later transition has a source.
        if (
            _manifest.verifier == address(0) ||
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

        _requirePin(_manifest.verifier, _manifest.verifierCodehash);
        _requirePin(_manifest.upgradeEngine, _manifest.upgradeEngineCodehash);
        // Live validation of both edges. RELEASE PROVENANCE is deliberately NOT checked here: a
        // permissionless manifest could name any "factory", so the attestation that both edges
        // are genuine write-once CTMRelease instances comes from the CTM itself — its canonical
        // `releaseFactory` is enforced in `_storeCurrentRelease`, which every pinned release
        // (bootstrap and every transition target) passes through, and the executor's release
        // edge check ties `fromRelease` to that same attested `currentRelease`.
        ICTMRelease(_manifest.newRelease).validate();
        ICTMRelease(_manifest.fromRelease).validate();

        // A SemVer patch bump changes no chain state by definition, so it must reuse the
        // departing release.
        {
            (uint32 oldMajor, uint32 oldMinor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_manifest.oldProtocolVersion));
            (uint32 newMajor, uint32 newMinor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_manifest.newProtocolVersion));
            if (oldMajor == newMajor && oldMinor == newMinor && _manifest.fromRelease != _manifest.newRelease) {
                revert PatchMustReuseRelease(_manifest.fromRelease, _manifest.newRelease);
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
        // A same-release transition is verifier/schedule-only: the derived facet/hash delta is
        // empty by construction, and it must not carry an L2 payload either.
        if (_manifest.fromRelease == _manifest.newRelease && hasL2Side) {
            revert SameReleaseTransitionHasPayload();
        }

        initialized = true;
        manifestHash = keccak256(abi.encode(_manifest));
        transitionOldProtocolVersion = _manifest.oldProtocolVersion;
        transitionNewProtocolVersion = _manifest.newProtocolVersion;
        transitionVerifier = _manifest.verifier;
        verifierCodehash = _manifest.verifierCodehash;
        transitionFromRelease = _manifest.fromRelease;
        transitionNewRelease = _manifest.newRelease;
        transitionUpgradeEngine = _manifest.upgradeEngine;
        upgradeEngineCodehash = _manifest.upgradeEngineCodehash;
        transitionOldProtocolVersionDeadline = _manifest.oldProtocolVersionDeadline;
        transitionUpgradeTimestamp = _manifest.upgradeTimestamp;

        uint256 length = _manifest.l2Plan.deployments.length;
        for (uint256 i = 0; i < length; ++i) {
            plan.deployments.push(_manifest.l2Plan.deployments[i]);
        }
        plan.delegateTo = _manifest.l2Plan.delegateTo;
        plan.delegateCalldata = _manifest.l2Plan.delegateCalldata;
        plan.factoryDepHashes = _manifest.l2Plan.factoryDepHashes;

        // Derive the L1 delta from the release pair and freeze it as final diamond cuts.
        Diamond.FacetCut[] memory facetCutsMemory = TransitionDeltaLib.deriveFacetCuts(
            ICTMRelease(_manifest.fromRelease),
            ICTMRelease(_manifest.newRelease)
        );
        length = facetCutsMemory.length;
        for (uint256 i = 0; i < length; ++i) {
            derivedFacetCuts.push(facetCutsMemory[i]);
        }
        (derivedBootloaderChange, derivedDefaultAccountChange, derivedEvmEmulatorChange) = TransitionDeltaLib
            .deriveHashChanges(ICTMRelease(_manifest.fromRelease), ICTMRelease(_manifest.newRelease));
    }

    function oldProtocolVersion() external view returns (uint256) {
        return transitionOldProtocolVersion;
    }

    function newProtocolVersion() external view returns (uint256) {
        return transitionNewProtocolVersion;
    }

    function verifier() external view returns (address) {
        return transitionVerifier;
    }

    function fromRelease() external view returns (address) {
        return transitionFromRelease;
    }

    function newRelease() external view returns (address) {
        return transitionNewRelease;
    }

    function upgradeEngine() external view returns (address) {
        return transitionUpgradeEngine;
    }

    function oldProtocolVersionDeadline() external view returns (uint256) {
        return transitionOldProtocolVersionDeadline;
    }

    function upgradeTimestamp() external view returns (uint256) {
        return transitionUpgradeTimestamp;
    }

    function facetCuts() external view returns (Diamond.FacetCut[] memory) {
        return derivedFacetCuts;
    }

    function baseSystemContractHashChanges() external view returns (bytes32, bytes32, bytes32) {
        return (derivedBootloaderChange, derivedDefaultAccountChange, derivedEvmEmulatorChange);
    }

    function l2Plan() external view returns (L2UpgradePlan memory) {
        return plan;
    }

    function validate() external view {
        if (!initialized) {
            revert RegistryUnknownKey();
        }
        ICTMRelease(transitionNewRelease).validate();
        ICTMRelease(transitionFromRelease).validate();
        _requirePin(transitionVerifier, verifierCodehash);
        _requirePin(transitionUpgradeEngine, upgradeEngineCodehash);
    }

    function verifyAll() external view returns (bool) {
        if (!initialized) {
            return false;
        }
        if (!ICTMRelease(transitionNewRelease).verifyAll() || !ICTMRelease(transitionFromRelease).verifyAll()) {
            return false;
        }
        return
            CodehashPinLib.pinHolds(transitionVerifier, verifierCodehash) &&
            CodehashPinLib.pinHolds(transitionUpgradeEngine, upgradeEngineCodehash);
    }

    function _requirePin(address _target, bytes32 _expectedCodehash) private view {
        CodehashPinLib.requirePin(_target, _expectedCodehash);
    }
}
