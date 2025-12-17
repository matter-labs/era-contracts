// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

// import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";

import {DefaultChainUpgrade} from "../default_upgrade/DefaultChainUpgrade.s.sol";

import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";

/// @notice For V31 we need to migrate all token balances on L1 NTV to AssetTracker, and from L1AssetTracker to GW AssetTracker.
contract ChainUpgrade_v31 is DefaultChainUpgrade {
    using stdToml for string;

    function run(address ctm, uint256 chainChainId) public override {
        super.run(ctm, chainChainId);
        migrateTokenBalanceFromNTV(config.bridgehubProxyAddress, block.chainid); // todo fix inputs.
    }

    function migrateTokenBalanceFromNTV(address _bridgehub, uint256 _chainId) public {
        address ntvAddress = address(
            IL1AssetRouter(address(IBridgehubBase(_bridgehub).assetRouter())).nativeTokenVault()
        );

        IL1AssetTracker l1AssetTracker = IL1NativeTokenVault(ntvAddress).l1AssetTracker();
        // For each token in the NTV bridgedTokens list, migrate the token balance to the L1AssetTracker
        INativeTokenVaultBase ntv = INativeTokenVaultBase(ntvAddress);

        uint256 bridgedTokensCount = ntv.bridgedTokensCount();
        for (uint256 i = 0; i < bridgedTokensCount; ++i) {
            bytes32 assetId = ntv.bridgedTokens(i);
            l1AssetTracker.migrateTokenBalanceFromNTVV31(_chainId, assetId);
        }
    }

    /// we have to migrate the token balance to GW if the chain is on GW.
}
