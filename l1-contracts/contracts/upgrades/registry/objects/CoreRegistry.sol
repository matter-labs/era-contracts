// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICoreRegistry} from "./ICoreRegistry.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {RegistryUnknownKey} from "../../../common/L1ContractErrors.sol";
import {CoreRegistryManifest, ProxyUpgradeRow} from "../RegistryTypes.sol";

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
    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

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
        ProxyUpgradeRowLib.validateRows(_manifest.contractRows);
        encodedManifest = abi.encode(_manifest);
    }

    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment governance compares
    ///         against the audited manifest. Computed from the stored encoding, not stored
    ///         separately: no contract reads it, and a second copy could only ever agree.
    function manifestHash() external view returns (bytes32) {
        return keccak256(encodedManifest);
    }

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() public view returns (CoreRegistryManifest memory) {
        return abi.decode(encodedManifest, (CoreRegistryManifest));
    }

    /*//////////////////////////////////////////////////////////////
                        ICoreRegistry (lookup logic)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoreRegistry
    function ecosystemRows() external view returns (ProxyUpgradeRow[] memory) {
        return getManifest().contractRows;
    }

    /// @inheritdoc ICoreRegistry
    function verifyAll() external view returns (bool) {
        return ProxyUpgradeRowLib.rowPinsHold(getManifest().contractRows);
    }

    /// @inheritdoc ICoreRegistry
    function validate() external view {
        ProxyUpgradeRowLib.requireRowPins(getManifest().contractRows);
    }
}
