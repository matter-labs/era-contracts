// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CodehashPin} from "./ContractIdentifiers.sol";
import {ICoreRegistry, EcosystemContractRow} from "./ICoreRegistry.sol";
import {
    RegistryAlreadyInitialized,
    RegistryCodehashMismatch,
    RegistryUnknownKey
} from "../../common/L1ContractErrors.sol";

/// @title Core (ecosystem-wide) registry — one instance per protocol upgrade.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Storage-backed and WRITE-ONCE — see `CTMRegistry` for the model: {initialize} pins
///         the full manifest exactly once, there is no other state-mutating function, and the
///         implementation is a fixed, audited-once contract, so a per-instance review is a pure
///         DATA check (read the getters or compare {manifestHash} against the audited manifest).
contract CoreRegistry is ICoreRegistry {
    /// @notice Everything a core registry instance pins, set exactly once by {initialize}.
    /// @dev Carries NO protocol version: version-schedule identity is owned by {CTMTransition}
    ///      (mirroring how {ICTMRelease} deliberately omits it). A core registry only pins the
    ///      ecosystem contract rows and the proxy admin they upgrade through.
    struct CoreRegistryManifest {
        address proxyAdmin;
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

    address internal proxyAdmin_;
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
        // Sentinel against pinning an empty manifest: a core registry must name the proxy admin
        // its ecosystem rows are upgraded through.
        if (_manifest.proxyAdmin == address(0)) {
            revert RegistryUnknownKey();
        }
        initialized = true;
        manifestHash = keccak256(abi.encode(_manifest));

        proxyAdmin_ = _manifest.proxyAdmin;
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
    function ecosystemRows() external view returns (EcosystemContractRow[] memory) {
        return contractRows;
    }

    /// @inheritdoc ICoreRegistry
    function proxyAdmin() external view returns (address) {
        return proxyAdmin_;
    }

    /// @inheritdoc ICoreRegistry
    function verifyAll() external view returns (bool) {
        // An uninitialized registry has nothing pinned — it must not read as verified.
        if (!initialized) {
            return false;
        }
        uint256 pinsLength = codehashPins.length;
        for (uint256 i = 0; i < pinsLength; ++i) {
            if (codehashPins[i].target.codehash != codehashPins[i].expectedCodehash) {
                return false;
            }
        }
        return true;
    }

    function validate() external view {
        if (!initialized) {
            revert RegistryUnknownKey();
        }
        uint256 pinsLength = codehashPins.length;
        for (uint256 i = 0; i < pinsLength; ++i) {
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
