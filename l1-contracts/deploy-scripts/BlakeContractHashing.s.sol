// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {Utils} from "./Utils.sol";

contract BlakeContractHashing is Script {
    function run(string calldata fileName, string calldata contractName) public {
        bytes memory contractBytecode = Utils.readFoundryBytecodeL1(fileName, contractName);

        bytes32 result = Utils.blakeHashBytecode(contractBytecode);

        console.logBytes32(result);
    }
}
