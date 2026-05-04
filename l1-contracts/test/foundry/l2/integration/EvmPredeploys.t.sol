// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeployEvmPredeploys} from "deploy-scripts/chain/evm-predeploys/DeployEvmPredeploys.s.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AllowedBytecodeTypes, IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

contract EvmPredeploys is Test {
    using stdJson for string;

    DeployEvmPredeploys deployEvmPredeploys;

    function setUp() public {
        deployEvmPredeploys = new DeployEvmPredeploys();
    }

    //@check This doesn´t run with the current "yarn l1 test:foundry"
    function test_shouldDeployPredeploysIfEvmEmulatorEnabled() public {
        bytes memory data = abi.encodeCall(IL2ContractDeployer.allowedBytecodeTypesToDeploy, ());
        (bool res, bytes memory returnData) = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR.call(data);
        if (!res) {
            // L2 deployer not present (chain is too old). Skip explicitly so the run is visible
            // in test output rather than silently passing (F-070).
            vm.skip(true);
            return;
        }

        AllowedBytecodeTypes mode = abi.decode(returnData, (AllowedBytecodeTypes));
        if (mode == AllowedBytecodeTypes.EraVm) {
            // EVM emulation is not enabled on this chain; skip explicitly.
            vm.skip(true);
            return;
        }

        deployEvmPredeploys.run();

        // Verify every predeploy address declared in the data directory now has deployed code.
        // Mirrors the iteration in DeployEvmPredeploys.run()
        // (deploy-scripts/chain/evm-predeploys/DeployEvmPredeploys.s.sol:22-31).
        string memory dataPath = string.concat(vm.projectRoot(), "/../system-contracts/scripts/evm-predeploys-data/");
        Vm.DirEntry[] memory entries = vm.readDir(dataPath);
        assertGt(entries.length, 0, "no predeploy data files found at expected path");

        for (uint256 i = 0; i < entries.length; i++) {
            address predeployAddress = vm.readFile(entries[i].path).readAddress("$.address");
            assertGt(
                predeployAddress.code.length,
                0,
                string.concat("predeploy missing code at ", vm.toString(predeployAddress))
            );
        }
    }
}