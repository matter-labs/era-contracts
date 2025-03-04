// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployErc20Script} from "deploy-scripts/DeployErc20.s.sol";

contract TokenDeployer is Test {
    address[] tokens;
    DeployErc20Script private deployScript;

    function _deployTokens() internal {
        vm.setEnv(
            "TOKENS_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-erc20.toml"
        );

        deployScript = new DeployErc20Script();
        deployScript.run();
        tokens = deployScript.getTokensAddresses();
    }

    // add this to be excluded from coverage report
    function testTokenDeployer() internal {}
}
