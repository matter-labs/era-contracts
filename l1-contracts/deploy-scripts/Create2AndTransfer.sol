// SPDX-License-Identifier: MIT

import {IOwnable} from "./interfaces/IOwnable.sol";

pragma solidity 0.8.24;

/// @title Create2AndTransfer
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Allows to deterministically create a contract with a fixed owner.
contract Create2AndTransfer {
    /// @notice The address of the contract deployed during inside the constructor.
    address public immutable deployedAddress;

    constructor(bytes memory bytecode, bytes32 salt, address owner) {
        address addr;
        assembly {
            addr := create2(0x0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        require(addr != address(0), "Create2: Failed on deploy");
        IOwnable(addr).transferOwnership(owner);

        deployedAddress = addr;
    }
}
