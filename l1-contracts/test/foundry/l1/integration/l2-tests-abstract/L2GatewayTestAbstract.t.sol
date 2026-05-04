// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {StdStorage, Test, console2 as console, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

import {
    L2_ASSET_ROUTER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

import {
    SETTLEMENT_LAYER_RELAY_SENDER,
    ZKChainCommitment,
    CHAIN_MIGRATION_TIME_WINDOW_START_TESTNET
} from "contracts/common/Config.sol";

import {
    BridgehubBurnCTMAssetData,
    BridgehubMintCTMAssetData,
    IBridgehubBase
} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {BridgehubBase} from "contracts/core/bridgehub/BridgehubBase.sol";

import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";

import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

import {BALANCE_CHANGE_VERSION} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {BalanceChange} from "contracts/common/Messaging.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";

import {LogFinder} from "test-utils/LogFinder.sol";

abstract contract L2GatewayTestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;
    using LogFinder for Vm.Log[];

    function _pauseDeposits(uint256 _chainId) public {
        pauseDepositsBeforeInitiatingMigration(L2_BRIDGEHUB_ADDR, _chainId);
        // As the priority queue was not empty before migration, we wait until the chain migration window starts
        vm.warp(block.timestamp + CHAIN_MIGRATION_TIME_WINDOW_START_TESTNET);
    }

    function test_gatewayShouldFinalizeDeposit() public {
        finalizeDeposit();
        assertEq(l2Bridgehub.ctmAssetIdFromAddress(address(chainTypeManager)), ctmAssetId, "ctmAssetId mismatch");
        assertEq(l2Bridgehub.ctmAssetIdFromChainId(mintChainId), ctmAssetId, "ctmAssetIdFromChainId mismatch");

        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        assertFalse(GettersFacet(diamondProxy).isPriorityQueueActive(), "Priority queue must not be active");
    }

    function test_gatewayNonEmptyPriorityQueueMigration() public {
        ZKChainCommitment memory commitment = abi.decode(exampleChainCommitment, (ZKChainCommitment));

        // Some non-zero value which would be the case if a chain existed before the
        // priority tree was added
        commitment.priorityTree.startIndex = 101;
        commitment.priorityTree.nextLeafIndex = 102;

        finalizeDepositWithCustomCommitment(abi.encode(commitment));

        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        GettersFacet getters = GettersFacet(diamondProxy);

        assertFalse(getters.isPriorityQueueActive(), "Priority queue must not be active");

        // Verify the priority tree state was carried over from the commitment.
        // PriorityTree.initFromCommitment copies startIndex / unprocessedIndex / _nextLeafIndex directly,
        // so getTotalPriorityTxs() (== startIndex + _nextLeafIndex) equals 101 + 102.
        assertEq(getters.getPriorityTreeStartIndex(), 101, "priority tree startIndex must be 101");
        assertEq(getters.getTotalPriorityTxs(), 101 + 102, "totalPriorityTxs must equal startIndex + nextLeafIndex");
        assertTrue(getters.getPriorityTreeRoot() != bytes32(0), "priority tree root must be set after migration");
    }

    function test_forwardToL2OnGateway_L2() public {
        finalizeDeposit();

        // Verify the chain is registered before forwarding
        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        assertTrue(diamondProxy != address(0), "Diamond proxy should be deployed");

        // Snapshot priority-tree state on the destination diamond so the post-call asserts can
        // verify the forward queued a priority op (rather than only that the call did not revert).
        // Done before vm.prank so the view calls do not consume it.
        GettersFacet getters = GettersFacet(diamondProxy);
        uint256 priorityCountBefore = getters.getTotalPriorityTxs();
        uint256 queueSizeBefore = getters.getPriorityQueueSize();

        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IChainAssetHandlerBase.migrationNumber.selector),
            abi.encode(1)
        );
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            baseTokenAssetId: bytes32(0),
            baseTokenAmount: 0,
            assetId: bytes32(0),
            amount: 0,
            tokenOriginChainId: 0,
            originToken: address(0)
        });

        vm.recordLogs();
        vm.prank(SETTLEMENT_LAYER_RELAY_SENDER);
        l2InteropCenter.forwardTransactionOnGatewayWithBalanceChange(mintChainId, bytes32(0), 0, balanceChange);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify both Mailbox events fired on the destination diamond for the forwarded priority tx.
        logs.requireOneFrom("NewPriorityRequestId(uint256,bytes32)", diamondProxy);
        logs.requireOneFrom("NewRelayedPriorityTransaction(uint256,bytes32,uint64)", diamondProxy);

        // Verify the priority queue depth on the destination diamond grew by exactly one.
        assertEq(getters.getTotalPriorityTxs(), priorityCountBefore + 1, "totalPriorityTxs must increment by 1");
        assertEq(getters.getPriorityQueueSize(), queueSizeBefore + 1, "priorityQueueSize must increment by 1");

        // Verify the chain is still registered on this layer after the forward.
        assertEq(l2Bridgehub.getZKChain(mintChainId), diamondProxy, "Chain registration must be unchanged after forward");
    }

    function test_withdrawFromGateway() public {
        finalizeDeposit();

        // Verify chain is registered before withdrawal
        address diamondProxyBefore = l2Bridgehub.getZKChain(mintChainId);
        assertTrue(diamondProxyBefore != address(0), "Diamond proxy should exist before withdrawal");

        clearPriorityQueue(address(coreAddresses.bridgehub.proxies.bridgehub), mintChainId);
        _pauseDeposits(mintChainId);
        address newAdmin = makeAddr("newAdmin");
        BridgehubBurnCTMAssetData memory data = BridgehubBurnCTMAssetData({
            chainId: mintChainId,
            ctmData: abi.encode(newAdmin, config.contracts.diamondCutData),
            chainData: abi.encode(chainTypeManager.protocolVersion())
        });

        // Snapshot migrationNumber so the post-call assert can verify it advances by exactly one.
        uint256 migrationNumberBefore = IChainAssetHandlerBase(L2_CHAIN_ASSET_HANDLER_ADDR).migrationNumber(mintChainId);

        vm.prank(ownerWallet);
        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes(""))
        );

        vm.recordLogs();
        l2AssetRouter.withdraw(ctmAssetId, abi.encode(data));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify WithdrawalInitiatedAssetRouter event content. The event has 2 indexed params
        // (l2Sender, assetId); chainId and assetData live in the data field.
        Vm.Log memory withdrawalLog = logs.requireOneFrom(
            "WithdrawalInitiatedAssetRouter(uint256,address,bytes32,bytes)",
            L2_ASSET_ROUTER_ADDR
        );
        assertEq(
            withdrawalLog.topics[1],
            bytes32(uint256(uint160(ownerWallet))),
            "WithdrawalInitiatedAssetRouter: l2Sender should be ownerWallet"
        );
        assertEq(
            withdrawalLog.topics[2],
            ctmAssetId,
            "WithdrawalInitiatedAssetRouter: assetId should match ctmAssetId"
        );
        (uint256 emittedChainId, bytes memory emittedAssetData) = abi.decode(withdrawalLog.data, (uint256, bytes));
        assertEq(emittedChainId, L1_CHAIN_ID, "WithdrawalInitiatedAssetRouter: destination chain must be L1");
        assertEq(
            keccak256(emittedAssetData),
            keccak256(abi.encode(data)),
            "WithdrawalInitiatedAssetRouter: assetData must match the encoded BurnCTMAssetData input"
        );

        // Verify the chain-asset-handler MigrationStarted event. 3 indexed params
        // (chainId, assetId, settlementLayerChainId); migrationNumber lives in the data field.
        Vm.Log memory migrationLog = logs.requireOneFrom(
            "MigrationStarted(uint256,uint256,bytes32,uint256)",
            L2_CHAIN_ASSET_HANDLER_ADDR
        );
        assertEq(uint256(migrationLog.topics[1]), mintChainId, "MigrationStarted: chainId mismatch");
        assertEq(migrationLog.topics[2], ctmAssetId, "MigrationStarted: assetId mismatch");

        // Verify migrationNumber on the chain-asset-handler advanced by exactly one.
        uint256 migrationNumberAfter = IChainAssetHandlerBase(L2_CHAIN_ASSET_HANDLER_ADDR).migrationNumber(mintChainId);
        assertEq(migrationNumberAfter, migrationNumberBefore + 1, "migrationNumber must increment by 1");

        // Verify the chain registration is preserved on this settlement layer until the migration is finalized elsewhere.
        assertEq(l2Bridgehub.getZKChain(mintChainId), diamondProxyBefore, "Chain registration must be unchanged after withdraw");
    }

    function test_finalizeDepositWithRealChainData() public {
        // This test verifies that finalizeDeposit works with explicitly encoded data
        // (rather than hardcoded hex data that can become stale)

        // Use the existing finalizeDeposit helper which uses explicit encoding
        finalizeDeposit();

        // Verify the CTM was properly registered
        assertEq(
            l2Bridgehub.ctmAssetIdFromAddress(address(chainTypeManager)),
            ctmAssetId,
            "CTM should be registered with correct asset ID"
        );
        assertEq(l2Bridgehub.ctmAssetIdFromChainId(mintChainId), ctmAssetId, "CTM asset ID from chain ID should match");

        // Verify the chain was deployed
        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        assertTrue(diamondProxy != address(0), "Diamond proxy should be deployed");

        // Verify the asset handler is configured (handler address should be non-zero)
        address handlerAddress = IAssetRouterBase(L2_ASSET_ROUTER_ADDR).assetHandlerAddress(ctmAssetId);
        assertTrue(handlerAddress != address(0), "Asset handler should be configured");
    }
}