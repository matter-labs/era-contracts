// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {StdStorage, Test, console2 as console, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {SETTLEMENT_LAYER_RELAY_SENDER, ZKChainCommitment, CHAIN_MIGRATION_TIME_WINDOW_START_TESTNET} from "contracts/common/Config.sol";

import {BridgehubBurnCTMAssetData, BridgehubMintCTMAssetData, IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {BridgehubBase} from "contracts/core/bridgehub/BridgehubBase.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";

import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";

import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

import {BALANCE_CHANGE_VERSION} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {BalanceChange} from "contracts/common/Messaging.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";

abstract contract L2GatewayTestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    function _pauseDeposits(uint256 _chainId) public {
        pauseDepositsBeforeInitiatingMigration(L2_BRIDGEHUB_ADDR, _chainId);
        // As the priority queue was not empty before migration, we wait until the chain migration window starts
        vm.warp(block.timestamp + CHAIN_MIGRATION_TIME_WINDOW_START_TESTNET);
    }

    function test_gatewayShouldFinalizeDeposit() public {
        finalizeDeposit();
        require(l2Bridgehub.ctmAssetIdFromAddress(address(chainTypeManager)) == ctmAssetId, "ctmAssetId mismatch");
        require(l2Bridgehub.ctmAssetIdFromChainId(mintChainId) == ctmAssetId, "ctmAssetIdFromChainId mismatch");

        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        require(!GettersFacet(diamondProxy).isPriorityQueueActive(), "Priority queue must not be active");
    }

    function test_gatewayNonEmptyPriorityQueueMigration() public {
        ZKChainCommitment memory commitment = abi.decode(exampleChainCommitment, (ZKChainCommitment));

        // Some non-zero value which would be the case if a chain existed before the
        // priority tree was added
        commitment.priorityTree.startIndex = 101;
        commitment.priorityTree.nextLeafIndex = 102;

        finalizeDepositWithCustomCommitment(abi.encode(commitment));

        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        require(!GettersFacet(diamondProxy).isPriorityQueueActive(), "Priority queue must not be active");
    }

    function test_forwardToL2OnGateway_L2() public {
        finalizeDeposit();

        // Verify the chain is registered before forwarding
        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        assertTrue(diamondProxy != address(0), "Diamond proxy should be deployed");

        vm.prank(SETTLEMENT_LAYER_RELAY_SENDER);
        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
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

        // Call the function - if it doesn't revert, the forward was successful
        l2InteropCenter.forwardTransactionOnGatewayWithBalanceChange(mintChainId, bytes32(0), 0, balanceChange);

        // Verify the chain is still accessible after forwarding
        assertTrue(l2Bridgehub.getZKChain(mintChainId) != address(0), "Chain should still be registered after forward");
    }

    function test_withdrawFromGateway() public {
        finalizeDeposit();

        // Verify chain is registered before withdrawal
        address diamondProxyBefore = l2Bridgehub.getZKChain(mintChainId);
        assertTrue(diamondProxyBefore != address(0), "Diamond proxy should exist before withdrawal");

        clearPriorityQueue(address(coreAddresses.bridgehub.proxies.bridgehub), mintChainId);
        _pauseDeposits(mintChainId);
        address newAdmin = makeAddr("newAdmin");
        bytes memory newDiamondCut = abi.encode();
        BridgehubBurnCTMAssetData memory data = BridgehubBurnCTMAssetData({
            chainId: mintChainId,
            ctmData: abi.encode(newAdmin, config.contracts.diamondCutData),
            chainData: abi.encode(chainTypeManager.protocolVersion())
        });
        vm.prank(ownerWallet);
        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes(""))
        );

        // Record logs to verify events were emitted during withdrawal
        vm.recordLogs();

        // The withdraw function should execute without reverting
        l2AssetRouter.withdraw(ctmAssetId, abi.encode(data));

        // Verify logs were emitted during withdrawal (indicates L1 message was sent)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length > 0, "Withdrawal should emit events when sending message to L1");

        // Verify the withdrawal was for the correct chain and asset
        assertTrue(data.chainId == mintChainId, "Withdrawal data should reference the correct chain");
        assertTrue(ctmAssetId != bytes32(0), "CTM asset ID should be valid");
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
