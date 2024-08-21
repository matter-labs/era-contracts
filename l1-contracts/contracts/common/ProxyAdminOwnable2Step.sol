// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The `ProxyAdmin` contract with 2 step ownership transfer.
contract ProxyAdminOwnable2Step is ProxyAdmin, Ownable2Step {
    /// @notice Starts the ownership transfer of the contract to a new account. Replaces the pending transfer if there is one.
    /// @param _newOwner The address to which ownership of the contract will be transferred.
    function transferOwnership(address _newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        super.transferOwnership({newOwner: _newOwner});
    }

    /// @notice Transfers ownership of the contract to a new account (`newOwner`) and deletes any pending owner.
    /// @param _newOwner The address to which ownership of the contract will be transferred.
    function _transferOwnership(address _newOwner) internal override(Ownable, Ownable2Step) {
        super._transferOwnership({newOwner: _newOwner});
    }
}
