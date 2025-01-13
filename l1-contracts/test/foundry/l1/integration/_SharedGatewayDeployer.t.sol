// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {GatewayPreparationForTests} from "./_GatewayPreparationForTests.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import "@openzeppelin/contracts-v4/utils/Strings.sol";

contract GatewayDeployer is L1ContractDeployer {
    GatewayPreparationForTests gatewayScript;

    function _initializeGatewayScript() internal {
        vm.setEnv("L1_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml");
        vm.setEnv("L1_OUTPUT", "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml");
        vm.setEnv(
            "ZK_CHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-zk-chain-10.toml"
        );
        vm.setEnv(
            "GATEWAY_AS_CHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-zk-chain-11.toml"
        );
        vm.setEnv(
            "GATEWAY_AS_CHAIN_OUTPUT",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-11.toml"
        );

        gatewayScript = new GatewayPreparationForTests();
        gatewayScript.run();
    }
}
