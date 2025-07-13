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
import {IAssetTracker} from "contracts/bridge/asset-tracker/IAssetTracker.sol";
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

    string constant gwRpcUrl = "http://localhost:3150";
    IAssetTracker l2AssetTracker = IAssetTracker(L2_ASSET_TRACKER_ADDR);
    INativeTokenVault l2NativeTokenVault = INativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

    function fundL2Address(uint256 chainId, address bridgehubAddress, address l2Address, uint256 amount) public {
        uint256 actualAmount;
        if (amount > 0) {
            actualAmount = amount;
        } else {
            actualAmount = 5 ether;
        }
        uint256 settlementLayer = IBridgehub(bridgehubAddress).settlementLayer(chainId);
        Utils.runL1L2Transaction(
            abi.encode(),
            1000000,
            actualAmount,
            new bytes[](0),
            l2Address,
            chainId,
            bridgehubAddress,
            address(0),
            l2Address
        );
        if (settlementLayer != block.chainid) {
            Utils.runL1L2Transaction(
                abi.encode(),
                1000000,
                actualAmount,
                new bytes[](0),
                l2Address,
                settlementLayer,
                bridgehubAddress,
                address(0),
                l2Address
            );
        }
    }

    function startTokenMigrationOnL2(uint256 chainId, string memory l2RpcUrl) public {
        // Get the list of tokens from L1NativeTokenVault
        (uint256 bridgedTokenCount, bytes32[] memory assetIds) = getBridgedTokenAssetIds();

        // Set the L2 RPC for this chain
        // vm.envString(string.concat("L2_RPC_URL_", vm.toString(chainId)));
        string[2][] memory urls = vm.rpcUrls();
        // console.log("l2RpcUrl", l2RpcUrl);
        console.log(block.chainid);

        // Set L2 RPC for each token and migrate balances
        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            bytes32 assetId = assetIds[i];

            // Call migrateTokenBalanceFromL2 on the AssetTracker
            console.log("Migrating token balance for assetId:", uint256(assetId));
            // vm.recordLogs();
            vm.broadcast();
            {
                l2AssetTracker.initiateL1ToGatewayMigrationOnL2(assetId);
            }
            // Get the logs
            Vm.Log[] memory entries = vm.getRecordedLogs();
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

    // function continueMigrationOnGateway(IBridgehub bridgehub, uint256 chainId, string memory l2RpcUrl) public {
    //     bytes32[] memory msgHashes = loadHashesFromStartTokenMigrationFile();

    //     uint256 bridgedTokenCount = msgHashes.length;
    //     FinalizeL1DepositParams[] memory finalizeL1DepositParams = new FinalizeL1DepositParams[](bridgedTokenCount);

    //     for (uint256 i = 0; i < bridgedTokenCount; i++) {
    //         finalizeL1DepositParams[i] = BroadcastUtils.getL2ToL1LogProof(msgHashes[i], l2RpcUrl);
    //     }

    //     // Make RPC call to get L2 to L1 message proof
    //     for (uint256 i = 0; i < bridgedTokenCount; i++) {
    //         bytes32 gwMsgHash = msgHashes[i];

    //         IAssetTracker l2AssetTracker = IAssetTracker(L2_ASSET_TRACKER_ADDR);
    //         vm.broadcast();
    //         l2AssetTracker.receiveMigrationOnGateway(finalizeL1DepositParams[i]);
    //     }
    // }

    function finishMigrationOnL1(IBridgehub bridgehub, uint256 chainId, string memory l2RpcUrl) public {
        IInteropCenter interopCenter = IInteropCenter(bridgehub.interopCenter());
        IAssetTracker l1AssetTracker = IAssetTracker(interopCenter.assetTracker());

        uint256 settlementLayer = IBridgehub(bridgehub).settlementLayer(chainId);
        bytes32[] memory msgHashes;
        if (settlementLayer != block.chainid) {
            msgHashes = loadHashesFromL2TokenMigrationFile();
        } else {
            require(false, "not implemented");
            // msgHashes = loadHashesFromGatewayTokenMigrationFile();
        }

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

        for (uint256 i = 0; i < bridgedTokenCount; i++) {
            // console.logBytes(abi.encodeCall(l1AssetTracker.receiveMigrationOnL1, (finalizeL1DepositParams[i])));
            bytes32 assetId;
            (, assetId, , , ) = abi.decode(
                finalizeL1DepositParams[i].message,
                (uint256, bytes32, uint256, uint256, bool)
            );
            if (l1AssetTracker.assetSettlementLayer(assetId) == block.chainid) {
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
            uint256 migrationNumber = l2AssetTracker.assetMigrationNumber(assetId);
            //  != block.chainid) {
            console.log("Token", vm.toString(assetId), "migration number", migrationNumber);
            // }
            // kl todo implement properly, compare agains interopCenter migration number.
        }
    }

    function loadHashesFromL2TokenMigrationFile() public returns (bytes32[] memory) {
        uint256 l2ChainId = 271;
        string memory startMigrationSelector = "/77fb1935-";
        return getHashesForChainAndSelector(l2ChainId, startMigrationSelector);
    }

    function loadHashesFromGatewayTokenMigrationFile() public returns (bytes32[] memory) {
        uint256 gwChainId = 506;
        string memory continueMigrationSelector = "/77fb1935-";
        return getHashesForChainAndSelector(gwChainId, continueMigrationSelector);
    }
}
