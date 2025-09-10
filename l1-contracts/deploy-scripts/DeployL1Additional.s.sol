// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {DeployL1Script} from "./DeployL1.s.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";

contract DeployL1Additional is DeployL1Script {
    function getL2BytecodeHash(string memory contractName) public view virtual override returns (bytes32) {
        return L2ContractHelper.hashL2Bytecode(getCreationCode(contractName, true));
    }
}
