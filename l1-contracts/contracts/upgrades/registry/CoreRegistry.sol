// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICoreRegistry, EcosystemContractRow} from "./ICoreRegistry.sol";
import {
    RegistryAlreadyInitialized,
    RegistryCodehashMismatch,
    RegistryUnknownKey,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";

/// @title Core (ecosystem-wide) registry — one instance per protocol upgrade.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Storage-backed and WRITE-ONCE — see `CTMRelease` for the model: {initialize} pins
///         the full manifest exactly once, there is no other state-mutating function, and the
///         implementation is a fixed, audited-once contract, so a per-instance review is a pure
///         DATA check (read the getters or compare {manifestHash} against the audited manifest).
/// @dev Rows are source-checked edges (`expectedOldImpl -> implNew`) with MANDATORY inline
///      codehash pins on every new implementation — no detached, optional pin list.
contract CoreRegistry is ICoreRegistry {
    /// @notice Everything a core registry instance pins, set exactly once by {initialize}.
    /// @dev Carries NO protocol version (version-schedule identity is owned by {CTMTransition})
    ///      and NO proxy admin (the `EcosystemUpgradeExecutor` is bound to its immutable
    ///      `ProxyAdmin`). A core registry pins ONLY the ecosystem contract rows.
    struct CoreRegistryManifest {
        EcosystemContractRow[] contractRows;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice One-shot guard: false until {initialize} runs, true forever after.
    bool public initialized;

    /// @notice `keccak256(abi.encode(manifest))` of the pinned manifest — a single 32-byte
    ///         commitment to every value this registry serves.
    bytes32 public manifestHash;

    EcosystemContractRow[] internal contractRows;

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
        // Sentinel against pinning an empty manifest.
        uint256 length = _manifest.contractRows.length;
        if (length == 0) {
            revert RegistryUnknownKey();
        }
        for (uint256 i = 0; i < length; ++i) {
            EcosystemContractRow calldata row = _manifest.contractRows[i];
            if (row.implNew != address(0)) {
                // An upgrading row is a full edge: known source, pinned target.
                if (row.proxy == address(0) || row.expectedOldImpl == address(0)) {
                    revert ZeroAddress();
                }
                _requirePin(row.implNew, row.implNewCodehash);
            }
        }
        initialized = true;
        manifestHash = keccak256(abi.encode(_manifest));

        for (uint256 i = 0; i < length; ++i) {
            contractRows.push(_manifest.contractRows[i]);
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
    function verifyAll() external view returns (bool) {
        // An uninitialized registry has nothing pinned — it must not read as verified.
        if (!initialized) {
            return false;
        }
        uint256 length = contractRows.length;
        for (uint256 i = 0; i < length; ++i) {
            if (
                contractRows[i].implNew != address(0) &&
                contractRows[i].implNew.codehash != contractRows[i].implNewCodehash
            ) {
                return false;
            }
        }
        return true;
    }

    function validate() external view {
        if (!initialized) {
            revert RegistryUnknownKey();
        }
        uint256 length = contractRows.length;
        for (uint256 i = 0; i < length; ++i) {
            if (contractRows[i].implNew != address(0)) {
                _requirePin(contractRows[i].implNew, contractRows[i].implNewCodehash);
            }
        }
    }

    function _requirePin(address _target, bytes32 _expectedCodehash) private view {
        bytes32 actualCodehash = _target.codehash;
        if (actualCodehash != _expectedCodehash) {
            revert RegistryCodehashMismatch(_target, _expectedCodehash, actualCodehash);
        }
    }
}
