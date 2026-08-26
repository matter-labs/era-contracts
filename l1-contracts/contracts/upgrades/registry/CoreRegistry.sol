// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICoreRegistry, EcosystemContractRow} from "./ICoreRegistry.sol";
import {CodehashPinLib} from "./CodehashPinLib.sol";
import {
    RegistryDuplicateProxyRow,
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

    /// @notice `keccak256(abi.encode(manifest))`. No contract reads this — it is a review aid, a
    ///         single value to compare against the audited manifest. Provenance is the codehash.
    bytes32 public manifestHash;

    /// @dev THE manifest; the getters read out of this rather than a transcribed copy.
    CoreRegistryManifest internal manifest;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Pins the full manifest. This contract has NO state-mutating function at all — the
    ///         manifest is written once, at construction, so write-once is structural rather than
    ///         a runtime guard, and `manifestHash` can never describe a stale object.
    /// @param _manifest The manifest to pin.
    constructor(CoreRegistryManifest memory _manifest) {
        // Sentinel against pinning an empty manifest.
        uint256 length = _manifest.contractRows.length;
        if (length == 0) {
            revert RegistryUnknownKey();
        }
        for (uint256 i = 0; i < length; ++i) {
            EcosystemContractRow memory row = _manifest.contractRows[i];
            // Every row is a REAL, unique edge: known source, pinned target, one row per proxy.
            // Placeholder rows (zero implNew) are refused — a contract not participating in the
            // upgrade simply has no row.
            if (row.proxy == address(0) || row.expectedOldImpl == address(0) || row.implNew == address(0)) {
                revert ZeroAddress();
            }
            _requirePin(row.implNew, row.implNewCodehash);
            for (uint256 j = 0; j < i; ++j) {
                if (_manifest.contractRows[j].proxy == row.proxy) {
                    revert RegistryDuplicateProxyRow(row.proxy);
                }
            }
        }
        manifestHash = keccak256(abi.encode(_manifest));

        // Field-by-field: the legacy codegen pipeline cannot copy a struct ARRAY from memory to
        // storage, so `manifest = _manifest` is not available here.
        for (uint256 i = 0; i < length; ++i) {
            manifest.contractRows.push(_manifest.contractRows[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ICoreRegistry (lookup logic)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoreRegistry
    function ecosystemRows() external view returns (EcosystemContractRow[] memory) {
        return manifest.contractRows;
    }

    /// @inheritdoc ICoreRegistry
    function verifyAll() external view returns (bool) {
        uint256 length = manifest.contractRows.length;
        for (uint256 i = 0; i < length; ++i) {
            if (!CodehashPinLib.pinHolds(manifest.contractRows[i].implNew, manifest.contractRows[i].implNewCodehash)) {
                return false;
            }
        }
        return true;
    }

    /// @inheritdoc ICoreRegistry
    function validate() external view {
        uint256 length = manifest.contractRows.length;
        for (uint256 i = 0; i < length; ++i) {
            _requirePin(manifest.contractRows[i].implNew, manifest.contractRows[i].implNewCodehash);
        }
    }

    function _requirePin(address _target, bytes32 _expectedCodehash) private view {
        CodehashPinLib.requirePin(_target, _expectedCodehash);
    }
}
