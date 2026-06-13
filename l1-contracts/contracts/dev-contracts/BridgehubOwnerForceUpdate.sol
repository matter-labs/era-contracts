// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Bridgehub} from "../bridgehub/Bridgehub.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice TEMPORARY implementation of the {Bridgehub} used ONLY to repair a misconfigured
/// proxy whose `_owner` slot is zero (the `initialize` call never set an owner).
/// @dev This contract is byte-for-byte identical to {Bridgehub} except for the addition of
/// the {forceSetOwner} function. Because it inherits {Bridgehub} unchanged, its storage
/// layout is identical to {Bridgehub}; in particular the OpenZeppelin `_owner` slot (slot 51)
/// is in the exact same position.
///
/// Intended usage (atomic, inside a single Governance operation):
///   1. `ProxyAdmin.upgradeAndCall(proxy, thisImpl, forceSetOwner(newOwner))`
///   2. `ProxyAdmin.upgrade(proxy, originalImpl)`
/// i.e. the proxy points at this implementation only for the duration of step 1 and is
/// immediately reverted to the original implementation in step 2.
contract BridgehubOwnerForceUpdate is Bridgehub {
    constructor(
        uint256 _l1ChainId,
        address _owner,
        uint256 _maxNumberOfZKChains
    ) Bridgehub(_l1ChainId, _owner, _maxNumberOfZKChains) {}

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
