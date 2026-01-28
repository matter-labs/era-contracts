// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

/**
 * @title InteropTest
 * @dev Integration test for anvil-interop environment
 * Tests that chains are deployed and basic interop functionality works
 */
contract InteropTest is Script {
    // Chain IDs from anvil-config.json
    uint256 constant L1_CHAIN_ID = 31337;
    uint256 constant L2_CHAIN_10 = 10;
    uint256 constant L2_CHAIN_11 = 11;
    uint256 constant L2_CHAIN_12 = 12;

    function run() external {
        console.log("===========================================");
        console.log("Running Anvil Interop Integration Tests");
        console.log("===========================================");

        // Read addresses from deployment-info.json
        string memory root = vm.projectRoot();
        string memory deploymentInfoPath = string.concat(root, "/scripts/anvil-interop/outputs/deployment-info.json");

        string memory json = vm.readFile(deploymentInfoPath);
        address bridgehubAddr = vm.parseJsonAddress(json, ".bridgehub");
        address assetRouterAddr = vm.parseJsonAddress(json, ".assetRouter");

        console.log("L1 Bridgehub:", bridgehubAddr);
        console.log("L1 AssetRouter:", assetRouterAddr);

        testChainRegistration(bridgehubAddr);
        testL1Connectivity(bridgehubAddr, assetRouterAddr);
        testL2Connectivity();

        console.log("");
        console.log("===========================================");
        console.log("All Integration Tests Passed!");
        console.log("===========================================");
    }

    function testChainRegistration(address bridgehubAddr) internal view {
        console.log("");
        console.log("Test 1: Checking chain registration...");

        IL1Bridgehub bridgehub = IL1Bridgehub(bridgehubAddr);

        // Check that L2 chains are registered
        address chain10 = bridgehub.getZKChain(L2_CHAIN_10);
        address chain11 = bridgehub.getZKChain(L2_CHAIN_11);
        address chain12 = bridgehub.getZKChain(L2_CHAIN_12);

        require(chain10 != address(0), "Chain 10 not registered");
        require(chain11 != address(0), "Chain 11 not registered");
        require(chain12 != address(0), "Chain 12 not registered");

        console.log("  Chain 10 deployed at:", chain10);
        console.log("  Chain 11 deployed at:", chain11);
        console.log("  Chain 12 deployed at:", chain12);
        console.log("  All chains registered successfully!");
    }

    function testL1Connectivity(address bridgehubAddr, address assetRouterAddr) internal view {
        console.log("");
        console.log("Test 2: Checking L1 contract connectivity...");

        IL1Bridgehub bridgehub = IL1Bridgehub(bridgehubAddr);
        IL1AssetRouter assetRouter = IL1AssetRouter(assetRouterAddr);

        // Verify bridgehub knows about asset router
        address bridgehubAssetRouter = address(bridgehub.assetRouter());
        require(bridgehubAssetRouter == assetRouterAddr, "AssetRouter mismatch");

        console.log("  Bridgehub -> AssetRouter:", bridgehubAssetRouter);
        console.log("  L1 contracts properly connected!");
    }

    function testL2Connectivity() internal {
        console.log("");
        console.log("Test 3: Checking L2 RPC connectivity...");

        // Test L2 chain 10
        vm.createSelectFork("http://127.0.0.1:4050");
        uint256 chain10Id = block.chainid;
        require(chain10Id == L2_CHAIN_10, "Chain 10 RPC not responding correctly");
        console.log("  L2 Chain 10 RPC responding, chainId:", chain10Id);

        // Test L2 chain 11
        vm.createSelectFork("http://127.0.0.1:4051");
        uint256 chain11Id = block.chainid;
        require(chain11Id == L2_CHAIN_11, "Chain 11 RPC not responding correctly");
        console.log("  L2 Chain 11 RPC responding, chainId:", chain11Id);

        // Test L2 chain 12
        vm.createSelectFork("http://127.0.0.1:4052");
        uint256 chain12Id = block.chainid;
        require(chain12Id == L2_CHAIN_12, "Chain 12 RPC not responding correctly");
        console.log("  L2 Chain 12 RPC responding, chainId:", chain12Id);

        console.log("  All L2 chains responding!");
    }
}
