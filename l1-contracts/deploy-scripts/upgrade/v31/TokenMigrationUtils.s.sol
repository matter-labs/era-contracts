// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";

/// @notice Shared token migration utilities for the v31 upgrade.
/// @dev Used by both EcosystemUpgrade_v31 (stage3) and ChainUpgrade_v31.
library TokenMigrationUtils {
    /// @notice Register all legacy bridged tokens in the AssetTracker.
    /// @dev Iterates through all bridged tokens in NTV and calls registerLegacyToken on the AssetTracker.
    function registerAllLegacyTokens(address _bridgehub) internal {
        address ntvAddress = address(
            IL1AssetRouter(address(IBridgehubBase(_bridgehub).assetRouter())).nativeTokenVault()
        );

        IL1AssetTracker l1AssetTracker = IL1NativeTokenVault(ntvAddress).l1AssetTracker();
        INativeTokenVaultBase ntv = INativeTokenVaultBase(ntvAddress);

        uint256 bridgedTokensCount = ntv.bridgedTokensCount();
        for (uint256 i = 0; i < bridgedTokensCount; ++i) {
            bytes32 assetId = ntv.bridgedTokens(i);
            l1AssetTracker.registerLegacyToken(assetId);
        }
    }

    /// @notice Migrate token balances for a specific chain from NTV to AssetTracker.
    function migrateTokenBalancesForChain(
        uint256 _chainId,
        L1NativeTokenVault _ntv,
        IL1AssetTracker _assetTracker
    ) internal {
        console.log("Processing chain:", _chainId);

        uint256 tokenCount = _ntv.bridgedTokensCount();

        for (uint256 j = 0; j < tokenCount; ++j) {
            bytes32 assetId = _ntv.bridgedTokens(j);

            // Check if there's a balance to migrate
            uint256 balance = _ntv.chainBalance(_chainId, assetId);
            if (balance > 0) {
                address tokenAddress = _ntv.tokenAddress(assetId);
                console.log("  Migrating token:", tokenAddress);
                console.log("  Balance:", balance);

                _assetTracker.registerLegacyToken(assetId);

                console.log("  Migration successful");
            }
        }
    }

    /// @notice Migrate token balances from NTV chainBalance to AssetTracker for all chains.
    function migrateAllTokenBalances(address _ntv, address _assetTracker, IBridgehubBase _bridgehub) internal {
        console.log("Migrating token balances...");

        L1NativeTokenVault ntv = L1NativeTokenVault(payable(_ntv));
        IL1AssetTracker assetTracker = IL1AssetTracker(_assetTracker);

        uint256 tokenCount = ntv.bridgedTokensCount();
        console.log("Number of bridged tokens:", tokenCount);

        // First, migrate balances for the L1 chain itself
        uint256 l1ChainId = block.chainid;
        console.log("Migrating L1 chain balances (chainId:", l1ChainId, ")");
        migrateTokenBalancesForChain(l1ChainId, ntv, assetTracker);

        // Get list of registered L2 chains
        uint256[] memory chainIds = _bridgehub.getAllZKChainChainIDs();
        console.log("Number of L2 chains:", chainIds.length);

        // For each L2 chain and each token, migrate the balance
        for (uint256 i = 0; i < chainIds.length; ++i) {
            migrateTokenBalancesForChain(chainIds[i], ntv, assetTracker);
        }

        console.log("Token balance migration complete");
    }

    /// @notice Register legacy bridged tokens (ETH) in NTV bridged tokens list.
    /// @dev For production use, this function should be extended to register all bridged tokens
    /// from a config file or by querying on-chain state. Currently only registers ETH for fresh deployments.
    function registerBridgedTokensInNTV(address _bridgehub) internal {
        console.log("Registering bridged tokens in NTV...");

        NativeTokenVaultBase ntv = NativeTokenVaultBase(
            address(IL1AssetRouter(address(IBridgehubBase(_bridgehub).assetRouter())).nativeTokenVault())
        );

        // For fresh deployments, register the ETH base token
        // ETH token address is 0x0000000000000000000000000000000000000001
        address ethTokenAddress = address(0x0000000000000000000000000000000000000001);

        bytes32 ethAssetId = ntv.assetId(ethTokenAddress);
        console.log("ETH token address:", ethTokenAddress);

        bytes32[] memory savedBridgedTokens = new bytes32[](1);
        savedBridgedTokens[0] = ethAssetId;

        console.log("Registering tokens, count:", savedBridgedTokens.length);

        for (uint256 i = 0; i < savedBridgedTokens.length; ++i) {
            bytes32 assetId = savedBridgedTokens[i];
            address tokenAddress = ntv.tokenAddress(assetId);
            console.log("  Registering assetId:", tokenAddress);

            ntv.addLegacyTokenToBridgedTokensList(tokenAddress);

            console.log("  Token registered successfully");
        }

        console.log("Bridged tokens registration complete");
    }
}
