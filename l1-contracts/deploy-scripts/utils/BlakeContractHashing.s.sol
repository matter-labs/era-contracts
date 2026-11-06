// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console2 as console} from "forge-std/Script.sol";

import {Utils} from "../utils/Utils.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";

contract BlakeContractHashing is Script {
    function run(string calldata fileName, string calldata contractName) public {
        bytes memory contractBytecode = BytecodeUtils.readBytecodeL1(true, fileName, contractName);

        bytes32 result = Utils.blakeHashBytecode(contractBytecode);

        console.logBytes32(result);
    }
}
