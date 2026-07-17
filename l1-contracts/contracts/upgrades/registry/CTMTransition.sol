// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CodehashPin} from "./ContractIdentifiers.sol";
import {ICTMRelease} from "./ICTMRelease.sol";
import {ICTMTransition, L2Deployment} from "./ICTMTransition.sol";
import {TransitionConvergenceLib} from "./TransitionConvergenceLib.sol";
import {UpgradeFacetSwap} from "../../state-transition/libraries/ProposedUpgradeLib.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {SemVer} from "../../common/libraries/SemVer.sol";
import {ProtocolVersionTooSmall} from "../ZkSyncUpgradeErrors.sol";
import {
    PatchMustReuseRelease,
    RegistryAlreadyInitialized,
    RegistryCodehashMismatch,
    RegistryUnknownKey,
    SameReleaseTransitionHasPayload,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";

/// @notice Storage-backed, write-once transition between two CTM releases.
contract CTMTransition is ICTMTransition {
    // solhint-disable-next-line gas-struct-packing
    struct TransitionManifest {
        address ctmProxy;
        uint256 oldProtocolVersion;
        uint256 newProtocolVersion;
        address verifier;
        address fromRelease;
        address newRelease;
        address defaultUpgrade;
        uint256 oldProtocolVersionDeadline;
        uint256 upgradeTimestamp;
        UpgradeFacetSwap[] facetTransitions;
        L2Deployment[] l2Deployments;
        address l2UpgradeDelegateTo;
        bytes l2UpgradeDelegateCalldata;
        uint256[] factoryDepHashes;
        bytes32 bootloaderHash;
        bytes32 defaultAccountHash;
        bytes32 evmEmulatorHash;
        CodehashPin[] codehashPins;
    }

    bool public initialized;
    bytes32 public manifestHash;

    address internal transitionCtmProxy;
    uint256 internal transitionOldProtocolVersion;
    uint256 internal transitionNewProtocolVersion;
    address internal transitionVerifier;
    address internal transitionFromRelease;
    address internal transitionNewRelease;
    address internal transitionDefaultUpgrade;
    uint256 internal transitionOldProtocolVersionDeadline;
    uint256 internal transitionUpgradeTimestamp;
    UpgradeFacetSwap[] internal transitionFacets;
    L2Deployment[] internal transitionL2Deployments;
    address internal l2UpgradeDelegateTo;
    bytes internal l2UpgradeDelegateCalldata;
    uint256[] internal transitionFactoryDepHashes;
    bytes32 internal bootloaderHash;
    bytes32 internal defaultAccountHash;
    bytes32 internal evmEmulatorHash;
    CodehashPin[] internal codehashPins;

    function initialize(TransitionManifest calldata _manifest) external {
        if (initialized) {
            revert RegistryAlreadyInitialized();
        }
        if (
            _manifest.ctmProxy == address(0) ||
            _manifest.newProtocolVersion == 0 ||
            _manifest.verifier == address(0) ||
            _manifest.newRelease == address(0) ||
            _manifest.defaultUpgrade == address(0)
        ) {
            revert ZeroAddress();
        }

        // A transition only ever moves the version forward. Chains enforce this individually at
        // execution (`BaseZkSyncUpgrade._setNewProtocolVersion`); enforcing it here keeps the
        // CTM from ever committing to a transition its chains would later reject.
        if (_manifest.newProtocolVersion <= _manifest.oldProtocolVersion) {
            revert ProtocolVersionTooSmall(_manifest.oldProtocolVersion, _manifest.newProtocolVersion);
        }

        ICTMRelease(_manifest.newRelease).validate();
        // `fromRelease` is `address(0)` ONLY for the migration hop from a pre-registry version
        // (v31 -> v32): the executor matches it against a CTM whose `currentRelease` is still
        // unset, and since every applied transition pins a non-zero release, a zero `fromRelease`
        // can never match again afterwards. When set, it must itself be a valid release.
        if (_manifest.fromRelease != address(0)) {
            ICTMRelease(_manifest.fromRelease).validate();
        }
        // A SemVer patch bump changes no chain state by definition, so it must reuse the
        // departing release — a patch targeting a different release would let new-chain genesis
        // state diverge from what existing chains run.
        {
            (uint32 oldMajor, uint32 oldMinor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_manifest.oldProtocolVersion));
            (uint32 newMajor, uint32 newMinor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_manifest.newProtocolVersion));
            if (oldMajor == newMajor && oldMinor == newMinor && _manifest.fromRelease != _manifest.newRelease) {
                revert PatchMustReuseRelease(_manifest.fromRelease, _manifest.newRelease);
            }
        }
        // A same-release transition (patch or otherwise) is verifier/schedule-only: targeting
        // the same release cannot imply ANY chain-state payload — no facet swaps, no L2
        // deployments or delegate call, no factory deps, no base-system hash changes.
        if (
            _manifest.fromRelease == _manifest.newRelease &&
            (_manifest.facetTransitions.length != 0 ||
                _manifest.l2Deployments.length != 0 ||
                _manifest.l2UpgradeDelegateTo != address(0) ||
                _manifest.l2UpgradeDelegateCalldata.length != 0 ||
                _manifest.factoryDepHashes.length != 0 ||
                _manifest.bootloaderHash != bytes32(0) ||
                _manifest.defaultAccountHash != bytes32(0) ||
                _manifest.evmEmulatorHash != bytes32(0))
        ) {
            revert SameReleaseTransitionHasPayload();
        }
        // Convergence: prove this transition actually produces `newRelease`. Applying its facet
        // swaps to `fromRelease`'s routing must reproduce `newRelease`'s routing, and its applied
        // base-system hash changes must reconcile with `newRelease`'s pinned hashes. Without this,
        // the transition path (existing chains) could drift from the release path (new chains).
        // Skipped for the pre-registry migration hop (`fromRelease == 0`), see the library docs.
        TransitionConvergenceLib.requireTransitionProducesRelease({
            _fromRelease: _manifest.fromRelease,
            _swaps: _manifest.facetTransitions,
            _newRelease: _manifest.newRelease,
            _bootloaderChange: _manifest.bootloaderHash,
            _defaultAccountChange: _manifest.defaultAccountHash,
            _evmEmulatorChange: _manifest.evmEmulatorHash
        });
        _validatePins(_manifest.codehashPins);

        initialized = true;
        manifestHash = keccak256(abi.encode(_manifest));
        transitionCtmProxy = _manifest.ctmProxy;
        transitionOldProtocolVersion = _manifest.oldProtocolVersion;
        transitionNewProtocolVersion = _manifest.newProtocolVersion;
        transitionVerifier = _manifest.verifier;
        transitionFromRelease = _manifest.fromRelease;
        transitionNewRelease = _manifest.newRelease;
        transitionDefaultUpgrade = _manifest.defaultUpgrade;
        transitionOldProtocolVersionDeadline = _manifest.oldProtocolVersionDeadline;
        transitionUpgradeTimestamp = _manifest.upgradeTimestamp;
        uint256 length = _manifest.facetTransitions.length;
        for (uint256 i = 0; i < length; ++i) {
            transitionFacets.push(_manifest.facetTransitions[i]);
        }
        length = _manifest.l2Deployments.length;
        for (uint256 i = 0; i < length; ++i) {
            transitionL2Deployments.push(_manifest.l2Deployments[i]);
        }
        l2UpgradeDelegateTo = _manifest.l2UpgradeDelegateTo;
        l2UpgradeDelegateCalldata = _manifest.l2UpgradeDelegateCalldata;
        transitionFactoryDepHashes = _manifest.factoryDepHashes;
        bootloaderHash = _manifest.bootloaderHash;
        defaultAccountHash = _manifest.defaultAccountHash;
        evmEmulatorHash = _manifest.evmEmulatorHash;
        length = _manifest.codehashPins.length;
        for (uint256 i = 0; i < length; ++i) {
            codehashPins.push(_manifest.codehashPins[i]);
        }
    }

    function ctmProxy() external view returns (address) {
        return transitionCtmProxy;
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

    function defaultUpgrade() external view returns (address) {
        return transitionDefaultUpgrade;
    }

    function oldProtocolVersionDeadline() external view returns (uint256) {
        return transitionOldProtocolVersionDeadline;
    }

    function upgradeTimestamp() external view returns (uint256) {
        return transitionUpgradeTimestamp;
    }

    function facetTransitions() external view returns (UpgradeFacetSwap[] memory) {
        return transitionFacets;
    }

    function l2Deployments() external view returns (L2Deployment[] memory) {
        return transitionL2Deployments;
    }

    function l2UpgradeDelegate() external view returns (address, bytes memory) {
        return (l2UpgradeDelegateTo, l2UpgradeDelegateCalldata);
    }

    function factoryDepHashes() external view returns (uint256[] memory) {
        return transitionFactoryDepHashes;
    }

    function baseSystemContractHashChanges() external view returns (bytes32, bytes32, bytes32) {
        return (bootloaderHash, defaultAccountHash, evmEmulatorHash);
    }

    function validate() external view {
        if (!initialized) {
            revert RegistryUnknownKey();
        }
        ICTMRelease(transitionNewRelease).validate();
        // Both pinned edges must be live at execution, not only the target (zero = migration hop).
        if (transitionFromRelease != address(0)) {
            ICTMRelease(transitionFromRelease).validate();
        }
        _validateStoredPins();
    }

    function verifyAll() external view returns (bool) {
        if (!initialized || !ICTMRelease(transitionNewRelease).verifyAll()) {
            return false;
        }
        if (transitionFromRelease != address(0) && !ICTMRelease(transitionFromRelease).verifyAll()) {
            return false;
        }
        uint256 length = codehashPins.length;
        for (uint256 i = 0; i < length; ++i) {
            if (codehashPins[i].target.codehash != codehashPins[i].expectedCodehash) {
                return false;
            }
        }
        return true;
    }

    function _validatePins(CodehashPin[] calldata _pins) private view {
        uint256 length = _pins.length;
        for (uint256 i = 0; i < length; ++i) {
            bytes32 actualCodehash = _pins[i].target.codehash;
            if (actualCodehash != _pins[i].expectedCodehash) {
                revert RegistryCodehashMismatch(_pins[i].target, _pins[i].expectedCodehash, actualCodehash);
            }
        }
    }

    function _validateStoredPins() private view {
        uint256 length = codehashPins.length;
        for (uint256 i = 0; i < length; ++i) {
            bytes32 actualCodehash = codehashPins[i].target.codehash;
            if (actualCodehash != codehashPins[i].expectedCodehash) {
                revert RegistryCodehashMismatch(
                    codehashPins[i].target,
                    codehashPins[i].expectedCodehash,
                    actualCodehash
                );
            }
        }
    }
}
