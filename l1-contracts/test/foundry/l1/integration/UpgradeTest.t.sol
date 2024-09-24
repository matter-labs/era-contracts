// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {EcosystemUpgrade} from "deploy-scripts/upgrade/EcosystemUpgrade.s.sol";
import {ChainUpgrade} from "deploy-scripts/upgrade/ChainUpgrade.s.sol";

string constant ECOSYSTEM_INPUT = "/test/foundry/l1/integration/upgrade-envs/script-config/mainnet.toml";
string constant ECOSYSTEM_OUTPUT  = "/test/foundry/l1/integration/upgrade-envs/script-out/mainnet.toml";
string constant CHAIN_INPUT = "/test/foundry/l1/integration/upgrade-envs/script-config/mainnet-era.toml";
string constant CHAIN_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/mainnet-era.toml";


contract UpgradeTest {

    EcosystemUpgrade generateUpgradeData;
    ChainUpgrade chainUpgrade;

    function setUp() public {
        generateUpgradeData = new EcosystemUpgrade();
        chainUpgrade = new ChainUpgrade();
    }

    function test_MainnetFork() public {
        // Firstly, we deploy all the contracts
        generateUpgradeData.prepareEcosystemContracts(
            ECOSYSTEM_INPUT,
            ECOSYSTEM_OUTPUT
        );

        chainUpgrade.prepareChain(
            ECOSYSTEM_INPUT,
            ECOSYSTEM_OUTPUT,
            CHAIN_INPUT,
            CHAIN_OUTPUT
        );

        // Secondly, we deploy the permanent rollup restriction
        // All permanent rollups MUST migrate to it before the upgrade 
    }
}