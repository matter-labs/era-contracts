// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL2AssetTracker} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {TokenBalanceMigrationData} from "contracts/common/Messaging.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IAssetTrackerDataEncoding} from "contracts/bridge/asset-tracker/IAssetTrackerDataEncoding.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";

import {GW_ASSET_TRACKER, L2_ASSET_ROUTER, L2_ASSET_TRACKER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {BroadcastUtils} from "../provider/BroadcastUtils.s.sol";
import {ZKSProvider} from "../provider/ZKSProvider.s.sol";

import {Utils} from "../Utils.sol";

/// @notice Scripts that is responsible for preparing the chain to become a gateway
/// @dev IMPORTANT: this script is not intended to be used in production.
/// TODO(EVM-925): support secure gateway deployment.
contract GatewayMigrateTokenBalances is BroadcastUtils, ZKSProvider {
    using stdJson for string;

    IAssetTrackerBase l2AssetTrackerBase = IAssetTrackerBase(L2_ASSET_TRACKER_ADDR);
    IL2AssetTracker l2AssetTracker = IL2AssetTracker(L2_ASSET_TRACKER_ADDR);
    INativeTokenVaultBase l2NativeTokenVault = INativeTokenVaultBase(L2_NATIVE_TOKEN_VAULT_ADDR);

    function startTokenMigrationOnL2OrGateway(
        bool toGateway,
        uint256 chainId,
        string memory l2RpcUrl,
        string memory gwRpcUrl
    ) public {
        // string memory originalRpcUrl = vm.activeRpcUrl();
        vm.createSelectFork(l2RpcUrl);
        (uint256 bridgedTokenCount, bytes32[] memory assetIds) = getBridgedTokenAssetIds();
        if (!toGateway) {
            vm.createSelectFork(gwRpcUrl);
            console.log("Forked to", gwRpcUrl);
        }

        // Set L2 RPC for each token and migrate balances
        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            bytes32 assetId = assetIds[i];

            console.log("Migrating token balance for assetId:", vm.toString(assetId));
            vm.broadcast();
            if (toGateway) {
                l2AssetTracker.initiateL1ToGatewayMigrationOnL2(assetId);
            } else {
                // console.log(l2AssetTracker.chainBalance(chainId, assetId));
                GW_ASSET_TRACKER.initiateGatewayToL1MigrationOnGateway(chainId, assetId);
            }
        }
    }

    function getBridgedTokenAssetIds() public returns (uint256 bridgedTokenCountPlusOne, bytes32[] memory assetIds) {
        // Get all registered tokens
        uint256 bridgedTokenCount = l2NativeTokenVault.bridgedTokensCount();
        bridgedTokenCountPlusOne = bridgedTokenCount + 1;
        assetIds = new bytes32[](bridgedTokenCountPlusOne);
        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            assetIds[i] = l2NativeTokenVault.bridgedTokens(i);
        }
        assetIds[bridgedTokenCount] = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
    }

    error InvalidFunctionSignature(bytes4 functionSignature);

    function finishMigrationOnL1(
        bool toGateway,
        IBridgehubBase bridgehub,
        uint256 chainId,
        uint256 gatewayChainId,
        string memory l2RpcUrl,
        string memory gwRpcUrl,
        bool onlyWaitForFinalization
    ) public {
        IL1AssetRouter assetRouter = IL1AssetRouter(address(bridgehub.assetRouter()));
        IL1NativeTokenVault l1NativeTokenVault = IL1NativeTokenVault(address(assetRouter.nativeTokenVault()));

        uint256 settlementLayer = IBridgehubBase(bridgehub).settlementLayer(chainId);
        bytes32[] memory msgHashes = loadHashesFromStartTokenMigrationFile(toGateway ? chainId : gatewayChainId);

        if (msgHashes.length == 0) {
            console.log("No messages found for chainId:", chainId);
            return;
        }

        uint256 bridgedTokenCount = msgHashes.length;
        FinalizeL1DepositParams[] memory finalizeL1DepositParams = new FinalizeL1DepositParams[](bridgedTokenCount);

        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            finalizeL1DepositParams[i] = getFinalizeWithdrawalParams(
                toGateway ? chainId : gatewayChainId,
                toGateway ? l2RpcUrl : gwRpcUrl,
                msgHashes[i],
                0
            );
        }

        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            if (finalizeL1DepositParams[i].merkleProof.length == 0) {
                continue;
            }
            waitForBatchToBeExecuted(address(bridgehub), chainId, finalizeL1DepositParams[i]);
            break;
        }

        if (onlyWaitForFinalization) {
            return;
        }

        IL1AssetTracker l1AssetTracker = IL1AssetTracker(address(l1NativeTokenVault.l1AssetTracker()));
        IAssetTrackerBase l1AssetTrackerBase = IAssetTrackerBase(address(l1AssetTracker));

        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            if (finalizeL1DepositParams[i].merkleProof.length == 0) {
                continue;
            }
            // console.logBytes(abi.encodeCall(l1AssetTracker.receiveMigrationOnL1, (finalizeL1DepositParams[i])));
            (bytes4 functionSignature, TokenBalanceMigrationData memory data) = DataEncoding
                .decodeTokenBalanceMigrationData(finalizeL1DepositParams[i].message);
            require(
                functionSignature == IAssetTrackerDataEncoding.receiveMigrationOnL1.selector,
                InvalidFunctionSignature(functionSignature)
            );
            if (!l1AssetTrackerBase.tokenMigrated(data.chainId, data.assetId)) {
                vm.broadcast();
                l1AssetTracker.receiveMigrationOnL1(finalizeL1DepositParams[i]);
            }
        }
    }

    function checkAllMigrated(uint256 chainId, string memory l2RpcUrl) public {
        (uint256 bridgedTokenCount, bytes32[] memory assetIds) = getBridgedTokenAssetIds();
        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            bytes32 assetId = assetIds[i];
            bool migrated = l2AssetTrackerBase.tokenMigratedThisChain(assetId);
            require(migrated, "Token not migrated");
        }
    }

    function loadHashesFromStartTokenMigrationFile(uint256 chainOrGatewayChainId) public returns (bytes32[] memory) {
        string memory selector = vm.toString(abi.encodeWithSelector(this.startTokenMigrationOnL2OrGateway.selector));
        // string(bytes4(this.startTokenMigrationOnL2OrGateway.selector))[2:10];
        string memory actualSelector = "0675d915";
        require(compareStrings(selector, string.concat("0x", actualSelector)), "Selector mismatch");
        string memory startMigrationSelector = string.concat("/", actualSelector, "-");
        return getHashesForChainAndSelector(chainOrGatewayChainId, startMigrationSelector);
    }
}
