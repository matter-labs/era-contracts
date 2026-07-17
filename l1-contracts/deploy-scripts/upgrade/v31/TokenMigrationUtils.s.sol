// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

/// @notice Shared token-registration utilities for the v31 upgrade.
/// @dev Used by `CoreUpgrade_v31.stage3` (post-governance NTV bridged-token registration).
/// The pre-v31 token-balance migration has been removed; only the NTV token registration remains.
library TokenMigrationUtils {
    using stdToml for string;

    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

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

    /// @notice Read the legacy L1 tokens to register from a TOML file.
    /// @dev Default path is the committed `upgrade-envs/v0.31.0-interopB/local-bridged-tokens.toml`
    ///      (used by local fixtures). `protocol-ops ecosystem stage3 --env <env>`
    ///      sets `UPGRADE_BRIDGED_TOKENS_INPUT_OVERRIDE` to the per-env file at
    ///      `/upgrade-envs/v0.31.0-interopB/<env>-bridged-tokens.toml` that the
    ///      discovery script (`scripts/discover-legacy-bridged-tokens.ts`)
    ///      generates. The anvil-interop test harness also uses the override
    ///      to point at its per-scenario fixture under `outputs/`.
    function _readConfiguredBridgedTokens() private view returns (address[] memory) {
        string memory inputPath = "/upgrade-envs/v0.31.0-interopB/local-bridged-tokens.toml";
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
