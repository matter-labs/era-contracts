// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {EcosystemUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
import {DefaultChainUpgrade} from "../../../../deploy-scripts/upgrade/default_upgrade/DefaultChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {Test} from "forge-std/Test.sol";
import {DefaultCTMUpgrade} from "../../../../deploy-scripts/upgrade/default_upgrade/DefaultCTMUpgrade.s.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {UpgradeIntegrationTestBase} from "./UpgradeTestShared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract UpgradeIntegrationTest_Local is
    UpgradeIntegrationTestBase,
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer
{
    function setUp() public {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        chainId = eraZKChainId;
        acceptPendingAdmin();
        PERMANENT_VALUES_INPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/permanent-ctm.toml";

        ECOSYSTEM_UPGRADE_INPUT = "/upgrade-envs/v0.31.0-interopB/local.toml";
        ECOSYSTEM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml";
        ECOSYSTEM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/local-core.toml";
        CTM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-ctm.toml";
        CTM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/local-ctm.toml";
        CHAIN_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-era.toml";
        CHAIN_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/local-gateway.toml";
        preparePermanentValues();
        setupUpgrade(true);
        address bridgehub = ecosystemUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        bytes32 eraBaseTokenAssetId = IBridgehubBase(bridgehub).baseTokenAssetId(eraZKChainId);

        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, 0), abi.encode(eraBaseTokenAssetId));
        internalTest();
    }

    function test_DefaultUpgrade_Local() public {
        /// we do the whole test in the setup, since it is very ram heavy.
        require(true, "test passed");
    }
}
