// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {HyperchainDeployer} from "./_SharedHyperchainDeployer.t.sol";
import {RegisterHyperchainsScript} from "./deploy-scripts/script/RegisterHyperchains.s.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

contract TestHyperchainDeployConfig is HyperchainDeployer {
    function test_saveAndReadHyperchainsConfig() public {
        RegisterHyperchainsScript deployScript = new RegisterHyperchainsScript();
        address someBaseAddress = makeAddr("baseToken");
        hyperchainsToDeploy.push(_getDefaultHyperchainDeployInfo("era", currentHyperChainId, ETH_TOKEN_ADDRESS));
        hyperchainsToDeploy.push(_getDefaultHyperchainDeployInfo("era2", currentHyperChainId + 1, someBaseAddress));

        saveHyperchainConfig();

        vm.setEnv(
            "HYPERCHAINS_CONFIG",
            "/test/foundry/integration/deploy-scripts/script-out/output-deploy-hyperchains.toml"
        );
        RegisterHyperchainsScript.HyperchainDescription[] memory descriptions = deployScript.readHyperchainsConfig();

        for (uint256 i = 0; i < descriptions.length; i++) {
            RegisterHyperchainsScript.HyperchainDescription memory description = descriptions[i];
            RegisterHyperchainsScript.HyperchainDescription memory hyperchain = hyperchainsToDeploy[i].description;

            assertEq(hyperchain.baseToken, description.baseToken);
            assertEq(hyperchain.bridgehubCreateNewChainSalt, description.bridgehubCreateNewChainSalt);

            assertEq(hyperchain.validiumMode, description.validiumMode);
            assertEq(hyperchain.validatorSenderOperatorCommitEth, description.validatorSenderOperatorCommitEth);
            assertEq(hyperchain.validatorSenderOperatorBlobsEth, description.validatorSenderOperatorBlobsEth);
            assertEq(hyperchain.hyperchainChainId, description.hyperchainChainId);
            assertEq(hyperchain.baseTokenGasPriceMultiplierNominator, description.baseTokenGasPriceMultiplierNominator);
            assertEq(
                hyperchain.baseTokenGasPriceMultiplierDenominator,
                description.baseTokenGasPriceMultiplierDenominator
            );
        }
    }
}
