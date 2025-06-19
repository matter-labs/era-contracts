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

    function test_Blake2s256Hash() public {
        bytes32 testHash = Utils.blakeHashBytecode(bytes("hello world"));

        assert(testHash == 0x9aec6806794561107e594b1f6a8a6b0c92a0cba9acf5e5e93cca06f781813b0b);
    }
}
