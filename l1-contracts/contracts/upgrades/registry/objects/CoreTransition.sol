// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICoreTransition} from "./ICoreTransition.sol";
import {L1_ECOSYSTEM_CONTRACT_COUNT} from "../libraries/ContractIdentifiers.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {RegistryUnknownKey} from "../../../common/L1ContractErrors.sol";
import {CoreTransitionManifest, ProxyUpgradeRow} from "../RegistryTypes.sol";

/// @title Core (ecosystem-wide) transition — one instance per protocol upgrade.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Storage-backed and WRITE-ONCE — see `CTMRelease` for the model: {initialize} pins
///         the full manifest exactly once, there is no other state-mutating function, and the
///         implementation is a fixed, audited-once contract, so a per-instance review is a pure
///         DATA check (read the getters or compare {manifestHash} against the audited manifest).
/// @dev Rows are source-checked edges (`expectedOldImpl -> implNew`). What each `implNew`
///      RUNS is what governance reviewed before approving this object; the object's own job
///      is to refuse a target that is not a deployed contract at all.
contract CoreTransition is ICoreTransition {
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
    /// @param _manifest The manifest to pin. Its inventory is the slot array indexed by
    ///        `L1EcosystemContract` (length checked against the enum's member count in `toRows`) —
    ///        every ecosystem contract has a slot, and a zero `implNew` is the "not upgraded"
    ///        statement, so the audited calldata shows what the upgrade leaves alone beside what it
    ///        changes. A reviewer still has to check those statements against the release: the
    ///        length check cannot tell an intended "leave alone" from a row preparation never
    ///        built (see {ProxyUpgradeRowLib.toRows}).
    constructor(CoreTransitionManifest memory _manifest) {
        ProxyUpgradeRow[] memory rows = ProxyUpgradeRowLib.toRows(_manifest.proxyUpgrades, L1_ECOSYSTEM_CONTRACT_COUNT);
        // Sentinel against pinning an empty manifest: a transition that upgrades nothing is not a
        // transition, it is a mistake.
        if (rows.length == 0) {
            revert RegistryUnknownKey();
        }
        ProxyUpgradeRowLib.validateRows(rows);
        encodedManifest = abi.encode(_manifest);
    }

    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment governance compares
    ///         against the audited manifest. Computed from the stored encoding, not stored
    ///         separately: no contract reads it, and a second copy could only ever agree.
    function manifestHash() external view returns (bytes32) {
        return keccak256(encodedManifest);
    }

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() public view returns (CoreTransitionManifest memory) {
        return abi.decode(encodedManifest, (CoreTransitionManifest));
    }

    /*//////////////////////////////////////////////////////////////
                        ICoreTransition (lookup logic)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoreTransition
    function ecosystemRows() external view returns (ProxyUpgradeRow[] memory) {
        return _rows();
    }

    /// @inheritdoc ICoreTransition
    function validate() external view {
        ProxyUpgradeRowLib.requireRowCode(_rows());
    }

    /// @dev THE enumeration of what this transition names: its participating rows. Every read and
    ///      the check surface walk this one list.
    function _rows() private view returns (ProxyUpgradeRow[] memory) {
        return ProxyUpgradeRowLib.toRows(getManifest().proxyUpgrades, L1_ECOSYSTEM_CONTRACT_COUNT);
    }
}
