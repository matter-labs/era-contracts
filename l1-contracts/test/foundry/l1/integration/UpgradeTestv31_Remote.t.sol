// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {Test} from "forge-std/Test.sol";

import {UpgradeIntegrationTestBase} from "./UpgradeTestShared.t.sol";

contract UpgradeIntegrationTest_Remote is UpgradeIntegrationTestBase {
    function setUp() public {
        ECOSYSTEM_INPUT = "/upgrade-envs/v0.31.0-interopB/shared.toml";
        ECOSYSTEM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/local-core.toml";
        PERMANENT_VALUES_INPUT = "/upgrade-envs/permanent-values/stage.toml";
        CHAIN_INPUT = "/upgrade-envs/v0.31.0-interopB/stage-gateway.toml";
        CHAIN_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/stage-gateway.toml";

        chainId = 123;
        setupUpgrade(false);
    }

    // NOTE: this test is currently testing "stage" - as mainnet is not upgraded yet.
    function test_DefaultUpgrade_MainnetFork() public {
        internalTest();
    }
}
