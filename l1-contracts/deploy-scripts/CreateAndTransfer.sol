// SPDX-License-Identifier: MIT
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

pragma solidity ^0.8.24;

contract CreateAndTransfer {
    constructor(bytes memory bytecode, bytes32 salt, address owner) {
        address addr;
        assembly {
            addr := create2(0x0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        require(addr != address(0), "Create2: Failed on deploy");
        ProxyAdmin proxy = ProxyAdmin(addr);
        proxy.transferOwnership(owner);
    }
}
