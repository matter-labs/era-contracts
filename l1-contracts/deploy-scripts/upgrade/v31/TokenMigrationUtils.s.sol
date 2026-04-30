// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

/// @notice Shared token migration utilities for the v31 upgrade.
/// @dev Used by both EcosystemUpgrade_v31 (stage3) and ChainUpgrade_v31.
library TokenMigrationUtils {
    using stdToml for string;

    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

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
            // Skip tokens that are already registered to avoid reverting with AssetAlreadyRegistered.
            if (!IAssetTrackerBase(address(l1AssetTracker)).isAssetRegistered(assetId)) {
                l1AssetTracker.registerLegacyToken(assetId);
            }
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

                // Skip tokens that are already registered to avoid reverting with AssetAlreadyRegistered.
                if (!IAssetTrackerBase(address(_assetTracker)).isAssetRegistered(assetId)) {
                    _assetTracker.registerLegacyToken(assetId);
                }

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

    /// @notice Register legacy bridged tokens in the NTV bridged tokens list for v31 stage3.
    /// @dev Registers ETH plus any extra legacy L1 tokens declared in the dedicated bridged-tokens TOML.
    function registerBridgedTokensInNTV(address _bridgehub) internal {
        console.log("Registering bridged tokens in NTV...");

        NativeTokenVaultBase ntv = NativeTokenVaultBase(
            address(IL1AssetRouter(address(IBridgehubBase(_bridgehub).assetRouter())).nativeTokenVault())
        );

        address[] memory legacyTokens = _readConfiguredBridgedTokens();
        uint256 bridgedTokenCount = legacyTokens.length + 1;
        address[] memory tokensToRegister = new address[](bridgedTokenCount);
        tokensToRegister[0] = ETH_TOKEN_ADDRESS;

        for (uint256 i = 0; i < legacyTokens.length; ++i) {
            tokensToRegister[i + 1] = legacyTokens[i];
        }

        console.log("Registering tokens, count:", tokensToRegister.length);

        for (uint256 i = 0; i < tokensToRegister.length; ++i) {
            address tokenAddress = tokensToRegister[i];
            bytes32 assetId = ntv.assetId(tokenAddress);
            console.log("  Token address:", tokenAddress);

            if (assetId == bytes32(0)) {
                revert("Token assetId is not registered in NTV");
            }

            uint256 index = ntv.tokenIndex(assetId);
            if (index != 0 || (index == 0 && ntv.bridgedTokens(0) == assetId)) {
                console.log("  Token already present in bridged tokens list, skipping");
                continue;
            }

            ntv.addLegacyTokenToBridgedTokensList(tokenAddress);
            console.log("  Token registered successfully");
        }

        console.log("Bridged tokens registration complete");
    }

    function _readConfiguredBridgedTokens() private view returns (address[] memory) {
        string memory inputPath = "/script-config/v31-bridged-tokens.toml";
        try vm.envString("UPGRADE_BRIDGED_TOKENS_INPUT_OVERRIDE") returns (string memory overridePath) {
            inputPath = overridePath;
        } catch {}

        string memory upgradeToml = vm.readFile(string.concat(vm.projectRoot(), inputPath));

        if (!upgradeToml.keyExists("$.tokens.bridged_tokens")) {
            return new address[](0);
        }

        return upgradeToml.readAddressArray("$.tokens.bridged_tokens");
    }
}
