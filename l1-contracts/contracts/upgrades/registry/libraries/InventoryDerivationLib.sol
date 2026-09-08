// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTM_CONTRACT_COUNT} from "./ContractIdentifiers.sol";
import {CTMInventoryRow, PinnedContract, ProxyUpgradeRow} from "../RegistryTypes.sol";
import {
    InventoryAdminChanged,
    InventoryMemberAdded,
    InventoryMemberRemoved,
    InventoryProxyChanged,
    RegistryInventoryLengthMismatch
} from "../../../common/L1ContractErrors.sol";

/// @title Inventory-pair derivation.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Derives an upgrade's executable proxy rows from the CTM domain's CURRENT inventory and
///         the one it should end up at. Nothing is authored: the operations are a pure function of
///         the pair, exactly as a transition's facet cuts are a pure function of its release pair.
/// @dev The whole table, so a reviewer can check the rule rather than the rows:
///
///      | source  | target                    | operation                                     |
///      |---------|---------------------------|-----------------------------------------------|
///      | absent  | absent                    | none                                          |
///      | present | present, same impl        | none — the member is REUSED                   |
///      | present | present, different impl   | upgrade, source-checked against the source    |
///      | absent  | present                   | refused: registration is not a proxy upgrade  |
///      | present | absent                    | refused: removing a live member is not either |
///      | present | present, different proxy  | refused                                       |
///      | present | present, different admin  | refused: an admin change is another authority |
///
///      The three refusals are deliberate rather than unimplemented. Adding a member means making
///      the ecosystem USE a newly deployed contract, which is a registration call and not
///      expressible as a proxy swap; removing one and moving one between administrators are
///      likewise separate, reviewable operations. Refusing them here means a transition carrying
///      such a change cannot exist, rather than committing and then failing on every chain.
library InventoryDerivationLib {
    /// @notice The rows whose execution turns `_source` into `_target`.
    /// @param _source The inventory the CTM currently points at.
    /// @param _target The inventory this upgrade ends at.
    /// @param _callInitializeUpgrade Per member, whether its swap reinitializes. Authored on the
    ///        TRANSITION rather than on either inventory: an inventory describes state, and what
    ///        to run is the upgrade's business.
    /// @return rows Enum-indexed slots; an unchanged or absent member is an all-zero (inert) slot,
    ///         which {ProxyUpgradeRowLib.toRows} drops.
    function deriveProxyUpgrades(
        CTMInventoryRow[] memory _source,
        CTMInventoryRow[] memory _target,
        bool[] memory _callInitializeUpgrade
    ) internal pure returns (ProxyUpgradeRow[] memory rows) {
        if (_source.length != CTM_CONTRACT_COUNT) {
            revert RegistryInventoryLengthMismatch(CTM_CONTRACT_COUNT, _source.length);
        }
        if (_target.length != CTM_CONTRACT_COUNT) {
            revert RegistryInventoryLengthMismatch(CTM_CONTRACT_COUNT, _target.length);
        }
        if (_callInitializeUpgrade.length != CTM_CONTRACT_COUNT) {
            revert RegistryInventoryLengthMismatch(CTM_CONTRACT_COUNT, _callInitializeUpgrade.length);
        }

        rows = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        for (uint256 i = 0; i < CTM_CONTRACT_COUNT; ++i) {
            CTMInventoryRow memory from = _source[i];
            CTMInventoryRow memory to = _target[i];
            bool fromPresent = from.proxy != address(0);
            bool toPresent = to.proxy != address(0);

            if (!fromPresent && !toPresent) {
                continue;
            }
            if (!fromPresent) {
                revert InventoryMemberAdded(i, to.proxy);
            }
            if (!toPresent) {
                revert InventoryMemberRemoved(i, from.proxy);
            }
            if (from.proxy != to.proxy) {
                revert InventoryProxyChanged(i, from.proxy, to.proxy);
            }
            if (address(from.admin) != address(to.admin)) {
                revert InventoryAdminChanged(i, address(from.admin), address(to.admin));
            }
            if (from.implementation.addr == to.implementation.addr) {
                continue;
            }
            rows[i] = ProxyUpgradeRow({
                proxy: to.proxy,
                // The replay guard comes from the SOURCE inventory rather than being restated by
                // the manifest author: the upgrade applies only against the state it departs from.
                expectedOldImpl: from.implementation.addr,
                implNew: PinnedContract({addr: to.implementation.addr, codehash: to.implementation.codehash}),
                callInitializeUpgrade: _callInitializeUpgrade[i],
                admin: to.admin
            });
        }
    }
}
