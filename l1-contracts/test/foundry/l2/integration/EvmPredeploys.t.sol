// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeployEvmPredeploys} from "deploy-scripts/evm-predeploys/DeployEvmPredeploys.s.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {AllowedBytecodeTypes, IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

contract EvmPredeploys is Test {
    DeployEvmPredeploys deployEvmPredeploys;

    function setUp() public {
        deployEvmPredeploys = new DeployEvmPredeploys();
    }

    function test_shouldDeployPredeploysIfEvmEmulatorEnabled() public {
        bytes memory data = abi.encodeCall(IL2ContractDeployer.allowedBytecodeTypesToDeploy, ());
        (bool res, bytes memory returnData) = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR.call(data);
        if (!res) return; // Chain is too old

        AllowedBytecodeTypes mode = abi.decode(returnData, (AllowedBytecodeTypes));
        if (mode == AllowedBytecodeTypes.EraVm) {
            // EVM emulation is not enabled
            return;
        }

        deployEvmPredeploys.run();
    }
}
