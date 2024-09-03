// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {GatewayScript} from "deploy-scripts/Gateway.s.sol";
import {BASE_TOKEN_VIRTUAL_ADDRESS} from "contracts/common/Config.sol";
import "@openzeppelin/contracts-v4/utils/Strings.sol";

contract GatewayDeployer is L1ContractDeployer {
    GatewayScript gatewayScript;

    function _initializeGatewayScript() internal {
        vm.setEnv("L1_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml");
        vm.setEnv("L1_OUTPUT", "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml");
        vm.setEnv(
            "HYPERCHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-hyperchain-10.toml"
        );
        vm.setEnv(
            "GATEWAY_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-hyperchain-11.toml"
        );

        gatewayScript = new GatewayScript();
        gatewayScript.run();
    }
}
