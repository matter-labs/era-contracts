// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CodehashPin} from "./ContractIdentifiers.sol";
import {GenesisFacet, ICTMRelease} from "./ICTMRelease.sol";
import {
    RegistryAlreadyInitialized,
    RegistryCodehashMismatch,
    RegistryUnknownKey,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";

/// @notice Storage-backed, write-once description of one CTM release.
contract CTMRelease is ICTMRelease {
    // solhint-disable-next-line gas-struct-packing
    struct ReleaseManifest {
        bool isZKsyncOS;
        uint256 protocolVersion;
        address verifier;
        address diamondInit;
        GenesisFacet[] genesisFacets;
        bytes32 bootloaderHash;
        bytes32 defaultAccountHash;
        bytes32 evmEmulatorHash;
        bytes fixedForceDeploymentsData;
        address genesisUpgrade;
        bytes32 genesisBatchHash;
        bytes32 genesisBatchCommitment;
        uint64 genesisIndexRepeatedStorageChanges;
        CodehashPin[] codehashPins;
    }

    bool public initialized;
    bytes32 public manifestHash;

    bool internal zksyncOS;
    uint256 internal releaseProtocolVersion;
    address internal releaseVerifier;
    address internal releaseDiamondInit;
    GenesisFacet[] internal releaseGenesisFacets;
    bytes32 internal bootloaderHash;
    bytes32 internal defaultAccountHash;
    bytes32 internal evmEmulatorHash;
    bytes internal releaseFixedForceDeploymentsData;
    address internal genesisUpgrade;
    bytes32 internal genesisBatchHash;
    bytes32 internal genesisBatchCommitment;
    uint64 internal genesisIndexRepeatedStorageChanges;
    CodehashPin[] internal codehashPins;

    function initialize(ReleaseManifest calldata _manifest) external {
        if (initialized) {
            revert RegistryAlreadyInitialized();
        }
        if (
            _manifest.protocolVersion == 0 ||
            _manifest.verifier == address(0) ||
            _manifest.diamondInit == address(0) ||
            _manifest.genesisUpgrade == address(0)
        ) {
            revert ZeroAddress();
        }

        _validatePins(_manifest.codehashPins);

        initialized = true;
        manifestHash = keccak256(abi.encode(_manifest));
        zksyncOS = _manifest.isZKsyncOS;
        releaseProtocolVersion = _manifest.protocolVersion;
        releaseVerifier = _manifest.verifier;
        releaseDiamondInit = _manifest.diamondInit;
        uint256 length = _manifest.genesisFacets.length;
        for (uint256 i = 0; i < length; ++i) {
            releaseGenesisFacets.push(_manifest.genesisFacets[i]);
        }
        bootloaderHash = _manifest.bootloaderHash;
        defaultAccountHash = _manifest.defaultAccountHash;
        evmEmulatorHash = _manifest.evmEmulatorHash;
        releaseFixedForceDeploymentsData = _manifest.fixedForceDeploymentsData;
        genesisUpgrade = _manifest.genesisUpgrade;
        genesisBatchHash = _manifest.genesisBatchHash;
        genesisBatchCommitment = _manifest.genesisBatchCommitment;
        genesisIndexRepeatedStorageChanges = _manifest.genesisIndexRepeatedStorageChanges;
        length = _manifest.codehashPins.length;
        for (uint256 i = 0; i < length; ++i) {
            codehashPins.push(_manifest.codehashPins[i]);
        }
    }

    function isZKsyncOS() external view returns (bool) {
        return zksyncOS;
    }

    function protocolVersion() external view returns (uint256) {
        return releaseProtocolVersion;
    }

    function verifier() external view returns (address) {
        return releaseVerifier;
    }

    function diamondInit() external view returns (address) {
        return releaseDiamondInit;
    }

    function genesisFacets() external view returns (GenesisFacet[] memory) {
        return releaseGenesisFacets;
    }

    function baseSystemContractHashes() external view returns (bytes32, bytes32, bytes32) {
        return (bootloaderHash, defaultAccountHash, evmEmulatorHash);
    }

    function fixedForceDeploymentsData() external view returns (bytes memory) {
        return releaseFixedForceDeploymentsData;
    }

    function genesisParams() external view returns (address, bytes32, bytes32, uint64) {
        return (genesisUpgrade, genesisBatchHash, genesisBatchCommitment, genesisIndexRepeatedStorageChanges);
    }

    function validate() external view {
        if (!initialized) {
            revert RegistryUnknownKey();
        }
        _validateStoredPins();
    }

    function verifyAll() external view returns (bool) {
        if (!initialized) {
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
