// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandler} from "../bridgehub/ChainAssetHandler.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {IMessageRoot} from "../bridgehub/IMessageRoot.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice TEMPORARY implementation of the {ChainAssetHandler} used ONLY to repair a misconfigured
/// proxy whose `_owner` slot is zero (the `initialize` call never set an owner).
/// @dev This contract is identical to {ChainAssetHandler} except for the addition of the
/// {forceSetOwner} function. Because it inherits {ChainAssetHandler} unchanged it adds no storage
/// variables, so its storage layout is identical to {ChainAssetHandler}; in particular the
/// OpenZeppelin `_owner` slot (slot 51) is in the exact same position as in the deployed
/// implementation being repaired.
///
/// Intended usage (atomic, inside a single Governance operation):
///   1. `ProxyAdmin.upgradeAndCall(proxy, thisImpl, forceSetOwner(newOwner))`
///   2. `ProxyAdmin.upgrade(proxy, originalImpl)`
/// i.e. the proxy points at this implementation only for the duration of step 1 and is
/// immediately reverted to the original implementation in step 2.
contract ChainAssetHandlerOwnerForceUpdate is ChainAssetHandler {
    constructor(
        uint256 _l1ChainId,
        address _owner,
        IBridgehub _bridgehub,
        address _assetRouter,
        IMessageRoot _messageRoot
    ) ChainAssetHandler(_l1ChainId, _owner, _bridgehub, _assetRouter, _messageRoot) {}

    /// @notice Forcibly sets the contract owner, bypassing the usual access control.
    /// @dev Has no access control on purpose: it is only ever reachable while this temporary
    /// implementation is installed, which happens exclusively inside the atomic Governance
    /// operation described above (upgrade -> forceSetOwner -> upgrade back). There is no block
    /// in which an external actor could call it on the live proxy.
    /// @param addr The address that becomes the new owner.
    function forceSetOwner(address addr) external {
        _transferOwnership(addr);
    }
}
