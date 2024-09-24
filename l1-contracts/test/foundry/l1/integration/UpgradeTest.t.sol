// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {EcosystemUpgrade} from "deploy-scripts/upgrade/EcosystemUpgrade.s.sol";


contract UpgradeTest {

    EcosystemUpgrade generateUpgradeData;

    function setUp() public {
        generateUpgradeData = new EcosystemUpgrade();
    }

    function test_MainnetFork() public {
        // Firstly, we deploy all the contracts
        generateUpgradeData.prepareEcosystemContracts(
            "/test/foundry/l1/integration/upgrade-envs/script-config/mainnet.toml",
            "/test/foundry/l1/integration/upgrade-envs/script-out/mainnet.toml"
        );

        // Secondly, we deploy the permanent rollup restriction
        // All permanent rollups MUST migrate to it before the upgrade 
    }
}