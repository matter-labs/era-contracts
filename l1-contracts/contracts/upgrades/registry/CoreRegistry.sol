// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1EcosystemContract, CodehashPin} from "./ContractIdentifiers.sol";
import {ICoreRegistry} from "./ICoreRegistry.sol";
import {RegistryAlreadyInitialized, RegistryUnknownKey} from "../../common/L1ContractErrors.sol";

/// @title Core (ecosystem-wide) registry — one instance per protocol upgrade.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Storage-backed and WRITE-ONCE — see `CTMRegistry` for the model: {initialize} pins
///         the full manifest exactly once, there is no other state-mutating function, and the
///         implementation is a fixed, audited-once contract, so a per-instance review is a pure
///         DATA check (read the getters or compare {manifestHash} against the audited manifest).
contract CoreRegistry is ICoreRegistry {
    /// @dev One ecosystem contract's proxy and new-version implementation. A zero `implNew`
    ///      means "this upgrade pins no new implementation" (nothing to upgrade). Old-version
    ///      implementations are deliberately not recorded — the upgrade only needs where each
    ///      proxy must point AFTER it runs.
    struct EcosystemContractRow {
        L1EcosystemContract key;
        address proxy;
        address implNew;
    }

    /// @notice Everything a core registry instance pins, set exactly once by {initialize}.
    struct CoreRegistryManifest {
        uint256 oldProtocolVersion;
        uint256 newProtocolVersion;
        address proxyAdmin;
        address eraCTMRegistry;
        address zksyncOSCTMRegistry;
        EcosystemContractRow[] contractRows;
        CodehashPin[] codehashPins;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice One-shot guard: false until {initialize} runs, true forever after.
    bool public initialized;

    /// @notice `keccak256(abi.encode(manifest))` of the pinned manifest — a single 32-byte
    ///         commitment to every value this registry serves.
    bytes32 public manifestHash;

    uint256 internal oldProtocolVersion_;
    uint256 internal newProtocolVersion_;
    address internal proxyAdmin_;
    address internal eraCTMRegistry;
    address internal zksyncOSCTMRegistry;
    EcosystemContractRow[] internal contractRows;
    CodehashPin[] internal codehashPins;

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pins the full manifest. Callable exactly once; there is no other state-mutating
    ///         function on this contract.
    /// @param _manifest The manifest to pin.
    function initialize(CoreRegistryManifest calldata _manifest) external {
        if (initialized) {
            revert RegistryAlreadyInitialized();
        }
        if (_manifest.newProtocolVersion == 0) {
            revert RegistryUnknownKey();
        }
        initialized = true;
        manifestHash = keccak256(abi.encode(_manifest));

        oldProtocolVersion_ = _manifest.oldProtocolVersion;
        newProtocolVersion_ = _manifest.newProtocolVersion;
        proxyAdmin_ = _manifest.proxyAdmin;
        eraCTMRegistry = _manifest.eraCTMRegistry;
        zksyncOSCTMRegistry = _manifest.zksyncOSCTMRegistry;
        uint256 length = _manifest.contractRows.length;
        for (uint256 i = 0; i < length; ++i) {
            contractRows.push(_manifest.contractRows[i]);
        }
        length = _manifest.codehashPins.length;
        for (uint256 i = 0; i < length; ++i) {
            codehashPins.push(_manifest.codehashPins[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ICoreRegistry (lookup logic)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoreRegistry
    function oldProtocolVersion() external view returns (uint256) {
        return oldProtocolVersion_;
    }

    /// @inheritdoc ICoreRegistry
    function newProtocolVersion() external view returns (uint256) {
        return newProtocolVersion_;
    }

    /// @inheritdoc ICoreRegistry
    function proxyAddress(L1EcosystemContract _contract) external view returns (address) {
        uint256 rowsLength = contractRows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (contractRows[i].key == _contract) {
                return contractRows[i].proxy;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICoreRegistry
    function implAddress(L1EcosystemContract _contract) external view returns (address) {
        uint256 rowsLength = contractRows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (contractRows[i].key == _contract) {
                return contractRows[i].implNew;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICoreRegistry
    function ecosystemContractList() external view returns (L1EcosystemContract[] memory list) {
        uint256 rowsLength = contractRows.length;
        list = new L1EcosystemContract[](rowsLength);
        for (uint256 i = 0; i < rowsLength; ++i) {
            list[i] = contractRows[i].key;
        }
    }

    /// @inheritdoc ICoreRegistry
    function proxyAdmin() external view returns (address) {
        return proxyAdmin_;
    }

    /// @inheritdoc ICoreRegistry
    function ctmRegistry(bool _isZKsyncOS) external view returns (address) {
        return _isZKsyncOS ? zksyncOSCTMRegistry : eraCTMRegistry;
    }

    /// @inheritdoc ICoreRegistry
    function verifyAll() external view returns (bool) {
        uint256 pinsLength = codehashPins.length;
        for (uint256 i = 0; i < pinsLength; ++i) {
            if (codehashPins[i].target.codehash != codehashPins[i].expectedCodehash) {
                return false;
            }
        }
        return true;
    }
}
