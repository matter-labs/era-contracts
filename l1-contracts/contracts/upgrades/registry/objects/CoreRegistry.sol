// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICoreRegistry, EcosystemContractRow} from "./ICoreRegistry.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {
    RegistryDuplicateProxyRow,
    RegistryUnknownKey,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";

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

    /// @dev THE manifest, stored as its own ABI encoding — see {CTMRelease} for why the struct is
    ///      not transcribed into structured storage.
    bytes internal encodedManifest;

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
            // upgrade simply has no row. The codehash pins are checked by `validate()` against
            // live code, not here: the manifest supplies both halves of each pair, so a
            // construction-time check would only prove the pair self-consistent.
            if (row.proxy == address(0) || row.expectedOldImpl == address(0) || row.implNew == address(0)) {
                revert ZeroAddress();
            }
            for (uint256 j = 0; j < i; ++j) {
                if (_manifest.contractRows[j].proxy == row.proxy) {
                    revert RegistryDuplicateProxyRow(row.proxy);
                }
            }
        }
        encodedManifest = abi.encode(_manifest);
        manifestHash = keccak256(encodedManifest);
    }

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() public view returns (CoreRegistryManifest memory) {
        return abi.decode(encodedManifest, (CoreRegistryManifest));
    }

    /*//////////////////////////////////////////////////////////////
                        ICoreRegistry (lookup logic)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoreRegistry
    function ecosystemRows() external view returns (EcosystemContractRow[] memory) {
        return getManifest().contractRows;
    }

    /// @inheritdoc ICoreRegistry
    function verifyAll() external view returns (bool) {
        EcosystemContractRow[] memory rows = getManifest().contractRows;
        uint256 length = rows.length;
        for (uint256 i = 0; i < length; ++i) {
            if (!CodehashPinLib.pinHolds(rows[i].implNew, rows[i].implNewCodehash)) {
                return false;
            }
        }
        return true;
    }

    /// @inheritdoc ICoreRegistry
    function validate() external view {
        EcosystemContractRow[] memory rows = getManifest().contractRows;
        uint256 length = rows.length;
        for (uint256 i = 0; i < length; ++i) {
            _requirePin(rows[i].implNew, rows[i].implNewCodehash);
        }
    }

    function _requirePin(address _target, bytes32 _expectedCodehash) private view {
        CodehashPinLib.requirePin(_target, _expectedCodehash);
    }
}
