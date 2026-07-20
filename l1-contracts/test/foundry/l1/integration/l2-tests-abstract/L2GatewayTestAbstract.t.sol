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
    L2_INTEROP_CENTER_ADDR,
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

import {InteropBundle, InteropCall} from "contracts/common/Messaging.sol";
import {UnsafeBytes} from "contracts/common/libraries/UnsafeBytes.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";

import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";

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

        // Non-zero values, as for a chain that existed before the priority tree was added.
        commitment.priorityTree.startIndex = 101;
        commitment.priorityTree.nextLeafIndex = 102;

        finalizeDepositWithCustomCommitment(abi.encode(commitment));

        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        GettersFacet getters = GettersFacet(diamondProxy);

        assertFalse(getters.isPriorityQueueActive(), "Priority queue must not be active");

        // Priority tree state is copied verbatim from the commitment;
        // getTotalPriorityTxs() == startIndex + _nextLeafIndex.
        assertEq(getters.getPriorityTreeStartIndex(), 101, "priority tree startIndex must be 101");
        assertEq(getters.getTotalPriorityTxs(), 101 + 102, "totalPriorityTxs must equal startIndex + nextLeafIndex");
        assertTrue(getters.getPriorityTreeRoot() != bytes32(0), "priority tree root must be set after migration");
    }

    function test_forwardToL2OnGateway_L2() public {
        finalizeDeposit();

        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        assertTrue(diamondProxy != address(0), "Diamond proxy should be deployed");

        // Snapshot before vm.prank so the view calls do not consume the prank.
        GettersFacet getters = GettersFacet(diamondProxy);
        uint256 priorityCountBefore = getters.getTotalPriorityTxs();
        uint256 queueSizeBefore = getters.getPriorityQueueSize();

        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IChainAssetHandlerBase.migrationNumber.selector),
            abi.encode(1)
        );

        vm.recordLogs();
        vm.prank(SETTLEMENT_LAYER_RELAY_SENDER);
        l2InteropCenter.forwardTransactionOnGateway(mintChainId, bytes32(0), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        logs.requireOneFrom("NewPriorityRequestId(uint256,bytes32)", diamondProxy);
        logs.requireOneFrom("NewRelayedPriorityTransaction(uint256,bytes32,uint64)", diamondProxy);

        assertEq(getters.getTotalPriorityTxs(), priorityCountBefore + 1, "totalPriorityTxs must increment by 1");
        assertEq(getters.getPriorityQueueSize(), queueSizeBefore + 1, "priorityQueueSize must increment by 1");

        assertEq(
            l2Bridgehub.getZKChain(mintChainId),
            diamondProxy,
            "Chain registration must be unchanged after forward"
        );
    }

    function test_withdrawFromGateway() public {
        finalizeDeposit();

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

        uint256 migrationNumberBefore = IChainAssetHandlerBase(L2_CHAIN_ASSET_HANDLER_ADDR).migrationNumber(
            mintChainId
        );

        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes32(uint256(1)))
        );

        // The CTM-asset migration withdrawal rides the InteropCenter L2->L1 withdrawal-bundle path (see
        // {protocol-docs/chain-lifecycle.md}); the bundle sender (ownerWallet) is the chain admin whose
        // authorization the migration burn checks.
        bytes32 withdrawalBundleSalt = keccak256("ctm-migration-withdrawal-salt");
        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (withdrawalBundleSalt));
        vm.recordLogs();
        vm.prank(ownerWallet);
        l2InteropCenter.sendBundle(
            InteroperableAddress.formatEvmV1(L1_CHAIN_ID),
            DataEncoding.encodeInteropWithdrawalCallStarters(ctmAssetId, abi.encode(data)),
            bundleAttributes
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertWithdrawalBundleSent(logs, withdrawalBundleSalt, migrationNumberBefore);

        // MigrationStarted has 3 indexed params; migrationNumber lives in the data field.
        Vm.Log memory migrationLog = logs.requireOneFrom(
            "MigrationStarted(uint256,uint256,bytes32,uint256)",
            L2_CHAIN_ASSET_HANDLER_ADDR
        );
        assertEq(uint256(migrationLog.topics[1]), mintChainId, "MigrationStarted: chainId mismatch");
        assertEq(migrationLog.topics[2], ctmAssetId, "MigrationStarted: assetId mismatch");

        uint256 migrationNumberAfter = IChainAssetHandlerBase(L2_CHAIN_ASSET_HANDLER_ADDR).migrationNumber(mintChainId);
        assertEq(migrationNumberAfter, migrationNumberBefore + 1, "migrationNumber must increment by 1");

        // Registration is preserved on this settlement layer until the migration is finalized elsewhere.
        assertEq(
            l2Bridgehub.getZKChain(mintChainId),
            diamondProxyBefore,
            "Chain registration must be unchanged after withdraw"
        );
    }

    /// @notice Verifies the `InteropBundleSent` withdrawal bundle emitted for the CTM-asset chain migration:
    /// destination, sender commitment (bundle salt), and the single inner `finalizeDeposit` call.
    function _assertWithdrawalBundleSent(
        Vm.Log[] memory logs,
        bytes32 _bundleSalt,
        uint256 _migrationNumberBefore
    ) internal view {
        Vm.Log memory bundleLog = logs.requireOneFrom(
            "InteropBundleSent(bytes32,bytes32,(bytes1,uint256,uint256,bytes32,bytes32,(bytes1,bool,address,address,uint256,bytes)[],(bytes,bytes,bool,bytes32)))",
            L2_INTEROP_CENTER_ADDR
        );
        (, , InteropBundle memory sentBundle) = abi.decode(bundleLog.data, (bytes32, bytes32, InteropBundle));
        assertEq(sentBundle.sourceChainId, block.chainid, "InteropBundleSent: source chain mismatch");
        assertEq(sentBundle.destinationChainId, L1_CHAIN_ID, "InteropBundleSent: destination chain must be L1");
        // The bundle salt commits to the sender — the equivalent of an `l2Sender == ownerWallet` check.
        assertEq(
            sentBundle.interopBundleSalt,
            keccak256(abi.encodePacked(ownerWallet, _bundleSalt)),
            "InteropBundleSent: bundle salt must commit to ownerWallet as the sender"
        );
        assertEq(sentBundle.calls.length, 1, "InteropBundleSent: withdrawal bundle must hold exactly one call");
        InteropCall memory sentCall = sentBundle.calls[0];
        assertEq(
            sentCall.from,
            L2_ASSET_ROUTER_ADDR,
            "InteropBundleSent: call must originate from the L2 asset router"
        );
        assertEq(
            sentCall.to,
            address(l2AssetRouter.L1_ASSET_ROUTER()),
            "InteropBundleSent: call must target the L1 asset router"
        );
        // Inner call: finalizeDeposit(sourceChainId, assetId, transferData=BridgehubMintCTMAssetData).
        assertEq(
            bytes32(DataEncoding.getSelector(sentCall.data)),
            bytes32(AssetRouterBase.finalizeDeposit.selector),
            "InteropBundleSent: inner call must be finalizeDeposit"
        );
        (uint256 sentSourceChainId, bytes32 sentAssetId, bytes memory sentAssetData) = abi.decode(
            UnsafeBytes.readRemainingBytes(sentCall.data, 4),
            (uint256, bytes32, bytes)
        );
        assertEq(sentSourceChainId, block.chainid, "InteropBundleSent: finalizeDeposit chainId mismatch");
        assertEq(sentAssetId, ctmAssetId, "InteropBundleSent: assetId should match ctmAssetId");
        BridgehubMintCTMAssetData memory sentMintData = abi.decode(sentAssetData, (BridgehubMintCTMAssetData));
        assertEq(sentMintData.chainId, mintChainId, "InteropBundleSent: migrating chainId mismatch");
        assertEq(
            sentMintData.migrationNumber,
            _migrationNumberBefore + 1,
            "InteropBundleSent: mint data must carry the incremented migrationNumber"
        );
    }

    function test_finalizeDepositWithRealChainData() public {
        // Uses explicitly encoded commitment data rather than hardcoded hex that can become stale.
        finalizeDeposit();

        assertEq(
            l2Bridgehub.ctmAssetIdFromAddress(address(chainTypeManager)),
            ctmAssetId,
            "CTM should be registered with correct asset ID"
        );
        assertEq(l2Bridgehub.ctmAssetIdFromChainId(mintChainId), ctmAssetId, "CTM asset ID from chain ID should match");

        address diamondProxy = l2Bridgehub.getZKChain(mintChainId);
        assertTrue(diamondProxy != address(0), "Diamond proxy should be deployed");

        address handlerAddress = IAssetRouterBase(L2_ASSET_ROUTER_ADDR).assetHandlerAddress(ctmAssetId);
        assertTrue(handlerAddress != address(0), "Asset handler should be configured");
    }
}
