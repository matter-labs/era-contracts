// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {DefaultChainUpgrade} from "../default-upgrade/DefaultChainUpgrade.s.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";
import {TokenMigrationUtils} from "./TokenMigrationUtils.s.sol";

/// @notice For V31 we need to migrate all token balances on L1 NTV to AssetTracker, and from L1AssetTracker to GW AssetTracker.
contract ChainUpgrade_v31 is DefaultChainUpgrade {
    using stdToml for string;

    function run(address ctm, uint256 chainChainId) public override {
        super.run(ctm, chainChainId);
        TokenMigrationUtils.registerAllLegacyTokens(config.bridgehubProxyAddress);
    }

    /// we have to migrate the token balance to GW if the chain is on GW.
}
