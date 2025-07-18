// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Vm} from "forge-std/Vm.sol";
import {Script, console2 as console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetTracker, TokenBalanceMigrationData} from "contracts/bridge/asset-tracker/IAssetTracker.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";

import {L2_ASSET_TRACKER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BRIDGEHUB_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {BroadcastUtils} from "../provider/BroadcastUtils.s.sol";
import {ZKSProvider} from "../provider/ZKSProvider.s.sol";

import {Utils} from "../Utils.sol";

/// @notice Scripts that is responsible for preparing the chain to become a gateway
/// @dev IMPORTANT: this script is not intended to be used in production.
/// TODO(EVM-925): support secure gateway deployment.
contract GatewayMigrateTokenBalances is BroadcastUtils, ZKSProvider {
    using stdJson for string;

    IAssetTracker l2AssetTracker = IAssetTracker(L2_ASSET_TRACKER_ADDR);
    INativeTokenVault l2NativeTokenVault = INativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

    function startTokenMigrationOnL2OrGateway(
        bool isGateway,
        uint256 chainId,
        string memory l2RpcUrl,
        string memory gwRpcUrl
    ) public {
        // string memory originalRpcUrl = vm.activeRpcUrl();
        vm.createSelectFork(l2RpcUrl);
        (uint256 bridgedTokenCount, bytes32[] memory assetIds) = getBridgedTokenAssetIds();

        // Set L2 RPC for each token and migrate balances
        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            bytes32 assetId = assetIds[i];

            console.log("Migrating token balance for assetId:", uint256(assetId));
            vm.broadcast();
            if (isGateway) {
                vm.createSelectFork(gwRpcUrl);
                l2AssetTracker.initiateGatewayToL1MigrationOnGateway(chainId, assetId);
            } else {
                l2AssetTracker.initiateL1ToGatewayMigrationOnL2(assetId);
            }
        }
    }

    function getBridgedTokenAssetIds() public returns (uint256 bridgedTokenCount, bytes32[] memory assetIds) {
        // Get all registered tokens
        bridgedTokenCount = l2NativeTokenVault.bridgedTokensCount();
        assetIds = new bytes32[](bridgedTokenCount);
        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            assetIds[i] = l2NativeTokenVault.bridgedTokens(i);
        }
    }

    function finishMigrationOnL1(
        IBridgehub bridgehub,
        uint256 chainId,
        string memory l2RpcUrl,
        bool onlyWaitForFinalization
    ) public {
        IInteropCenter interopCenter = IInteropCenter(bridgehub.interopCenter());
        IAssetTracker l1AssetTracker = IAssetTracker(interopCenter.assetTracker());

        uint256 settlementLayer = IBridgehub(bridgehub).settlementLayer(chainId);
        bytes32[] memory msgHashes = loadHashesFromStartTokenMigrationFile();

        uint256 bridgedTokenCount = msgHashes.length;
        FinalizeL1DepositParams[] memory finalizeL1DepositParams = new FinalizeL1DepositParams[](bridgedTokenCount);

        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            finalizeL1DepositParams[i] = getFinalizeWithdrawalParams(chainId, l2RpcUrl, msgHashes[i], 0);
        }
        // console.log("msgHashes");
        // console.log(msgHashes.length);
        // console.log(vm.toString(msgHashes[0]));
        waitForBatchToBeExecuted(
            address(bridgehub),
            chainId,
            finalizeL1DepositParams[finalizeL1DepositParams.length - 1]
        );
        if (onlyWaitForFinalization) {
            return;
        }

        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            // console.logBytes(abi.encodeCall(l1AssetTracker.receiveMigrationOnL1, (finalizeL1DepositParams[i])));
            TokenBalanceMigrationData memory data = abi.decode(
                finalizeL1DepositParams[i].message,
                (TokenBalanceMigrationData)
            );
            if (l1AssetTracker.assetMigrationNumber(data.chainId, data.assetId) < data.migrationNumber) {
                vm.broadcast();
                l1AssetTracker.receiveMigrationOnL1(finalizeL1DepositParams[i]);
            }
        }
    }

    function checkAllMigrated(uint256 chainId, string memory l2RpcUrl) public {
        (uint256 bridgedTokenCount, bytes32[] memory assetIds) = getBridgedTokenAssetIds();
        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            bytes32 assetId = assetIds[i];
            // if (
            uint256 migrationNumber = l2AssetTracker.assetMigrationNumber(chainId, assetId);
            //  != block.chainid) {
            console.log("Token", vm.toString(assetId), "migration number", migrationNumber);
            // }
            // kl todo implement properly, compare agains interopCenter migration number.
        }
    }

    function loadHashesFromStartTokenMigrationFile() public returns (bytes32[] memory) {
        uint256 l2ChainId = 271;
        string memory selector = vm.toString(abi.encodeWithSelector(this.startTokenMigrationOnL2OrGateway.selector));
        // string(bytes4(this.startTokenMigrationOnL2OrGateway.selector))[2:10];
        string memory actualSelector = "0675d915";
        require(compareStrings(selector, string.concat("0x", actualSelector)), "Selector mismatch");
        string memory startMigrationSelector = string.concat("/", actualSelector, "-");
        return getHashesForChainAndSelector(l2ChainId, startMigrationSelector);
    }
}
