// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {GWAssetTracker} from "contracts/bridge/asset-tracker/GWAssetTracker.sol";

import {BalanceChange, TokenBalanceMigrationData, L2Log, TxStatus, InteropBundle, InteropCall, BundleAttributes, BUNDLE_IDENTIFIER, INTEROP_BUNDLE_VERSION, INTEROP_CALL_VERSION} from "contracts/common/Messaging.sol";
import {L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_CENTER_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_INTEROP_HANDLER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_COMPRESSOR_ADDR, L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER, MAX_BUILT_IN_CONTRACT_ADDR, L2_INTEROP_CENTER_ADDR as INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";

import {BALANCE_CHANGE_VERSION, TOKEN_BALANCE_MIGRATION_DATA_VERSION, INTEROP_BALANCE_CHANGE_VERSION} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";

import {InvalidCanonicalTxHash, RegisterNewTokenNotAllowed, InvalidFunctionSignature, InvalidBuiltInContractMessage, InvalidEmptyMessageRoot, InvalidL2ShardId, InvalidServiceLog, InvalidInteropBalanceChange} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {Unauthorized, ChainIdNotRegistered, InvalidMessage, ReconstructionMismatch, InvalidInteropCalldata} from "contracts/common/L1ContractErrors.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {IMigrator} from "contracts/state-transition/chain-interfaces/IMigrator.sol";
import {ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IInteropHandler} from "contracts/interop/IInteropHandler.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";

import {L2_TO_L1_LOGS_MERKLE_TREE_DEPTH, L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH} from "contracts/common/Config.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {DynamicIncrementalMerkleMemory} from "contracts/common/libraries/DynamicIncrementalMerkleMemory.sol";
import {GWAssetTrackerTestHelper} from "./GWAssetTracker.t.sol";

contract GWAssetTrackerExtendedTest is Test {
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    GWAssetTrackerTestHelper public gwAssetTracker;
    address public mockBridgehub;
    address public mockMessageRoot;
    address public mockNativeTokenVault;
    address public mockChainAssetHandler;
    address public mockZKChain;
    address public mockAssetRouter;

    uint256 public constant L1_CHAIN_ID = 1;
    uint256 public constant CHAIN_ID = 2;
    uint256 public constant MIGRATION_NUMBER = 10;
    bytes32 public constant ASSET_ID = keccak256("assetId");
    bytes32 public constant CANONICAL_TX_HASH = keccak256("canonicalTxHash");
    address public constant ORIGIN_TOKEN = address(0x123);
    uint256 public constant ORIGIN_CHAIN_ID = 3;
    uint256 public constant AMOUNT = 1000;
    bytes32 public constant BASE_TOKEN_ASSET_ID = keccak256("baseTokenAssetId");
    uint256 public constant BASE_TOKEN_AMOUNT = 500;

    function setUp() public {
        // Deploy GWAssetTrackerTestHelper
        gwAssetTracker = new GWAssetTrackerTestHelper();

        // Create mock addresses
        mockBridgehub = makeAddr("mockBridgehub");
        mockMessageRoot = makeAddr("mockMessageRoot");
        mockNativeTokenVault = makeAddr("mockNativeTokenVault");
        mockChainAssetHandler = makeAddr("mockChainAssetHandler");
        mockZKChain = makeAddr("mockZKChain");
        mockAssetRouter = makeAddr("mockAssetRouter");

        // Mock the L2 contract addresses
        vm.etch(L2_BRIDGEHUB_ADDR, address(mockBridgehub).code);
        vm.etch(L2_MESSAGE_ROOT_ADDR, address(mockMessageRoot).code);
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, address(mockNativeTokenVault).code);
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, address(mockChainAssetHandler).code);
        vm.etch(L2_ASSET_ROUTER_ADDR, address(mockAssetRouter).code);

        // Set up the contract
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setAddresses(L1_CHAIN_ID);

        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(1)
        );
    }

    // Helper function to build proper merkle tree root
    function _buildLogsMerkleRoot(L2Log[] memory logs) internal pure returns (bytes32) {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(L2_TO_L1_LOGS_MERKLE_TREE_DEPTH);
        tree.setup(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH);

        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 hashedLog = MessageHashing.getLeafHashFromLog(logs[i]);
            tree.push(hashedLog);
        }

        tree.extendUntilEnd();
        return tree.root();
    }

    function _buildInteropPerCallInput(
        uint256 _call0Value,
        uint256 _call1Value,
        uint256 _callIndex,
        bool _includeCenter
    ) internal returns (ProcessLogsInput memory input, bytes32 chainBatchRoot) {
        InteropCall[] memory calls = new InteropCall[](2);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: address(0x1111),
            from: address(0x2222),
            value: _call0Value,
            data: ""
        });
        calls[1] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: address(0x3333),
            from: address(0x4444),
            value: _call1Value,
            data: ""
        });

        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: CHAIN_ID,
            destinationChainId: CHAIN_ID,
            interopBundleSalt: keccak256("bundleSalt"),
            calls: calls,
            bundleAttributes: BundleAttributes({executionAddress: "", unbundlerAddress: ""})
        });

        bytes memory bundleBytes = abi.encode(bundle);
        bytes memory interopCenterMessage = bytes.concat(BUNDLE_IDENTIFIER, bundleBytes);
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(CHAIN_ID, bundleBytes);
        bytes memory interopHandlerMessage = abi.encodePacked(
            IInteropHandler.executeBundle.selector,
            bundleHash,
            bytes32(_callIndex)
        );

        uint256 logsLength = _includeCenter ? 2 : 1;
        L2Log[] memory logs = new L2Log[](logsLength);
        bytes[] memory messages = new bytes[](logsLength);
        if (_includeCenter) {
            logs[0] = L2Log({
                l2ShardId: 0,
                isService: true,
                txNumberInBatch: 0,
                sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                key: bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR))),
                value: keccak256(interopCenterMessage)
            });
            messages[0] = interopCenterMessage;
        }

        uint256 handlerIndex = _includeCenter ? 1 : 0;
        logs[handlerIndex] = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(uint160(L2_INTEROP_HANDLER_ADDR))),
            value: keccak256(interopHandlerMessage)
        });
        messages[handlerIndex] = interopHandlerMessage;

        bytes32 emptyMessageRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);
        bytes32 logsRoot = _buildLogsMerkleRoot(logs);
        chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMessageRoot));

        input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: logs,
            messages: messages,
            chainBatchRoot: chainBatchRoot,
            messageRoot: emptyMessageRoot
        });
    }

    // Test onlyChain modifier - unauthorized case (line 78)
    function test_ProcessLogsAndMessages_Unauthorized() public {
        ProcessLogsInput memory input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: new L2Log[](0),
            messages: new bytes[](0),
            chainBatchRoot: bytes32(0),
            messageRoot: bytes32(0)
        });

        // Mock getZKChain to return a different address
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(address(0x999))
        );

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        gwAssetTracker.processLogsAndMessages(input);
    }

    // Test processLogsAndMessages with invalid message (line 223)
    function test_ProcessLogsAndMessages_InvalidMessage() public {
        bytes memory wrongMessage = bytes("wrongMessage");
        bytes memory correctMessage = bytes("correctMessage");

        L2Log[] memory logs = new L2Log[](1);
        logs[0] = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR))),
            value: keccak256(wrongMessage)
        });

        bytes[] memory messages = new bytes[](1);
        messages[0] = correctMessage;

        bytes32 emptyMessageRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);
        bytes32 logsRoot = _buildLogsMerkleRoot(logs);
        bytes32 chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMessageRoot));

        ProcessLogsInput memory input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: logs,
            messages: messages,
            chainBatchRoot: chainBatchRoot,
            messageRoot: emptyMessageRoot
        });

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        vm.prank(mockZKChain);
        vm.expectRevert(InvalidMessage.selector);
        gwAssetTracker.processLogsAndMessages(input);
    }

    // Test processLogsAndMessages with invalid L2 shard ID
    function test_ProcessLogsAndMessages_InvalidL2ShardId() public {
        bytes memory message = bytes("testMessage");

        L2Log[] memory logs = new L2Log[](1);
        logs[0] = L2Log({
            l2ShardId: 1, // Invalid shard ID
            isService: true,
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR))),
            value: keccak256(message)
        });

        bytes[] memory messages = new bytes[](1);
        messages[0] = message;

        bytes32 emptyMessageRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);
        bytes32 logsRoot = _buildLogsMerkleRoot(logs);
        bytes32 chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMessageRoot));

        ProcessLogsInput memory input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: logs,
            messages: messages,
            chainBatchRoot: chainBatchRoot,
            messageRoot: emptyMessageRoot
        });

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        vm.prank(mockZKChain);
        vm.expectRevert(InvalidL2ShardId.selector);
        gwAssetTracker.processLogsAndMessages(input);
    }

    // Test processLogsAndMessages with invalid service log
    function test_ProcessLogsAndMessages_InvalidServiceLog() public {
        bytes memory message = bytes("testMessage");

        L2Log[] memory logs = new L2Log[](1);
        logs[0] = L2Log({
            l2ShardId: 0,
            isService: false, // Invalid - should be true
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR))),
            value: keccak256(message)
        });

        bytes[] memory messages = new bytes[](1);
        messages[0] = message;

        bytes32 emptyMessageRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);
        bytes32 logsRoot = _buildLogsMerkleRoot(logs);
        bytes32 chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMessageRoot));

        ProcessLogsInput memory input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: logs,
            messages: messages,
            chainBatchRoot: chainBatchRoot,
            messageRoot: emptyMessageRoot
        });

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        vm.prank(mockZKChain);
        vm.expectRevert(InvalidServiceLog.selector);
        gwAssetTracker.processLogsAndMessages(input);
    }

    // Test processLogsAndMessages with interop handler message (line 231)
    function test_ProcessLogsAndMessages_InteropHandler() public {
        // First, set up an interop balance change
        bytes32 bundleHash = keccak256("bundleHash");
        bytes memory message = abi.encodePacked(
            IInteropHandler.executeBundle.selector,
            bundleHash,
            bytes32(uint256(0))
        );

        L2Log[] memory logs = new L2Log[](1);
        logs[0] = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(uint160(L2_INTEROP_HANDLER_ADDR))),
            value: keccak256(message)
        });

        bytes[] memory messages = new bytes[](1);
        messages[0] = message;

        bytes32 emptyMessageRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);
        bytes32 logsRoot = _buildLogsMerkleRoot(logs);
        bytes32 chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMessageRoot));

        ProcessLogsInput memory input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: logs,
            messages: messages,
            chainBatchRoot: chainBatchRoot,
            messageRoot: emptyMessageRoot
        });

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        // Mock message root addChainBatchRoot
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)", CHAIN_ID, 1, chainBatchRoot),
            abi.encode()
        );

        vm.prank(mockZKChain);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropBalanceChange.selector, bundleHash));
        gwAssetTracker.processLogsAndMessages(input);
    }

    function test_ProcessLogsAndMessages_InteropHandler_PerCall() public {
        gwAssetTracker.setChainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID, 1000);
        uint256 call0Value = 100;
        uint256 call1Value = 200;
        (ProcessLogsInput memory input, bytes32 chainBatchRoot) = _buildInteropPerCallInput(
            call0Value,
            call1Value,
            1,
            true
        );

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        // Mock message root addChainBatchRoot
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)", CHAIN_ID, 1, chainBatchRoot),
            abi.encode()
        );

        uint256 balanceBefore = gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID);

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), balanceBefore - call0Value);
    }

    function test_ProcessLogsAndMessages_InteropHandler_PerCall_TwoSteps() public {
        gwAssetTracker.setChainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID, 1000);
        uint256 call0Value = 100;
        uint256 call1Value = 200;

        (ProcessLogsInput memory inputFirst, bytes32 chainBatchRootFirst) = _buildInteropPerCallInput(
            call0Value,
            call1Value,
            0,
            true
        );

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        // Mock message root addChainBatchRoot for first tx
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)", CHAIN_ID, 1, chainBatchRootFirst),
            abi.encode()
        );

        uint256 balanceBefore = gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID);

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(inputFirst);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), balanceBefore - call1Value);

        (ProcessLogsInput memory inputSecond, bytes32 chainBatchRootSecond) = _buildInteropPerCallInput(
            call0Value,
            call1Value,
            1,
            false
        );

        // Mock message root addChainBatchRoot for second tx
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)", CHAIN_ID, 1, chainBatchRootSecond),
            abi.encode()
        );

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(inputSecond);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), balanceBefore);
    }

    // Test processLogsAndMessages with base token system contract message (lines 233, 510, 516-517, 521)
    function test_ProcessLogsAndMessages_BaseToken() public {
        uint256 withdrawAmount = 100;
        address l1Receiver = address(0x456);

        // Create message using abi.encodePacked (matching DataEncoding decodeBaseTokenFinalizeWithdrawalData format)
        bytes memory message = abi.encodePacked(
            IMailboxImpl.finalizeEthWithdrawal.selector,
            l1Receiver,
            withdrawAmount
        );

        L2Log[] memory logs = new L2Log[](1);
        logs[0] = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(uint160(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR))),
            value: keccak256(message)
        });

        bytes[] memory messages = new bytes[](1);
        messages[0] = message;

        bytes32 emptyMessageRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);
        bytes32 logsRoot = _buildLogsMerkleRoot(logs);
        bytes32 chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMessageRoot));

        ProcessLogsInput memory input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: logs,
            messages: messages,
            chainBatchRoot: chainBatchRoot,
            messageRoot: emptyMessageRoot
        });

        // Need to set up initial balance for the chain first
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });
        vm.prank(INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, CANONICAL_TX_HASH, balanceChange);

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        // Mock message root addChainBatchRoot
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)", CHAIN_ID, 1, chainBatchRoot),
            abi.encode()
        );

        uint256 balanceBefore = gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID);

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);

        // Verify balance was decreased (line 521)
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), balanceBefore - withdrawAmount);
    }

    // Test processLogsAndMessages with compressor message (line 240)
    function test_ProcessLogsAndMessages_Compressor() public {
        bytes memory message = bytes("compressorMessage");

        L2Log[] memory logs = new L2Log[](1);
        logs[0] = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(uint160(L2_COMPRESSOR_ADDR))),
            value: keccak256(message)
        });

        bytes[] memory messages = new bytes[](1);
        messages[0] = message;

        bytes32 emptyMessageRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);
        bytes32 logsRoot = _buildLogsMerkleRoot(logs);
        bytes32 chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMessageRoot));

        ProcessLogsInput memory input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: logs,
            messages: messages,
            chainBatchRoot: chainBatchRoot,
            messageRoot: emptyMessageRoot
        });

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        // Mock message root addChainBatchRoot
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)", CHAIN_ID, 1, chainBatchRoot),
            abi.encode()
        );

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    // Test processLogsAndMessages with known code storage message (line 242)
    function test_ProcessLogsAndMessages_KnownCodeStorage() public {
        bytes memory message = bytes("knownCodeMessage");

        L2Log[] memory logs = new L2Log[](1);
        logs[0] = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(uint160(L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR))),
            value: keccak256(message)
        });

        bytes[] memory messages = new bytes[](1);
        messages[0] = message;

        bytes32 emptyMessageRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);
        bytes32 logsRoot = _buildLogsMerkleRoot(logs);
        bytes32 chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMessageRoot));

        ProcessLogsInput memory input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: logs,
            messages: messages,
            chainBatchRoot: chainBatchRoot,
            messageRoot: emptyMessageRoot
        });

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        // Mock message root addChainBatchRoot
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)", CHAIN_ID, 1, chainBatchRoot),
            abi.encode()
        );

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    // Test processLogsAndMessages with invalid built-in contract (line 244)
    function test_ProcessLogsAndMessages_InvalidBuiltInContract() public {
        bytes memory message = bytes("invalidMessage");
        bytes32 invalidBuiltInKey = bytes32(uint256(MAX_BUILT_IN_CONTRACT_ADDR - 1));

        L2Log[] memory logs = new L2Log[](1);
        logs[0] = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: invalidBuiltInKey,
            value: keccak256(message)
        });

        bytes[] memory messages = new bytes[](1);
        messages[0] = message;

        bytes32 emptyMessageRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);
        bytes32 logsRoot = _buildLogsMerkleRoot(logs);
        bytes32 chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMessageRoot));

        ProcessLogsInput memory input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: logs,
            messages: messages,
            chainBatchRoot: chainBatchRoot,
            messageRoot: emptyMessageRoot
        });

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        vm.prank(mockZKChain);
        vm.expectRevert(abi.encodeWithSelector(InvalidBuiltInContractMessage.selector, 0, 0, invalidBuiltInKey));
        gwAssetTracker.processLogsAndMessages(input);
    }

    // Test failed deposit handling (lines 318, 322)
    function test_ProcessLogsAndMessages_FailedDeposit() public {
        // First, create a balance increase
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });
        vm.prank(INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, CANONICAL_TX_HASH, balanceChange);

        // Now process a failed deposit log
        L2Log[] memory logs = new L2Log[](1);
        logs[0] = L2Log({
            l2ShardId: 0,
            isService: false,
            txNumberInBatch: 0,
            sender: L2_BOOTLOADER_ADDRESS,
            key: CANONICAL_TX_HASH,
            value: bytes32(uint256(TxStatus.Failure))
        });

        bytes32 emptyMessageRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);
        bytes32 logsRoot = _buildLogsMerkleRoot(logs);
        bytes32 chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMessageRoot));

        ProcessLogsInput memory input = ProcessLogsInput({
            chainId: CHAIN_ID,
            batchNumber: 1,
            logs: logs,
            messages: new bytes[](0),
            chainBatchRoot: chainBatchRoot,
            messageRoot: emptyMessageRoot
        });

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock base token asset ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );

        // Mock message root addChainBatchRoot
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)", CHAIN_ID, 1, chainBatchRoot),
            abi.encode()
        );

        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);

        // Verify balances were decreased (lines 318, 322)
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), 0);
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), 0);
    }

    // Test requestPauseDepositsForChain success (line 543)
    function test_RequestPauseDepositsForChain_Success() public {
        // Mock getZKChain to return a valid chain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Mock pauseDepositsOnGateway
        vm.mockCall(mockZKChain, abi.encodeWithSelector(IMigrator.pauseDepositsOnGateway.selector), abi.encode());

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.requestPauseDepositsForChain(CHAIN_ID);
    }

    // Test confirmMigrationOnGateway with saved balance (lines 630-631)
    function test_ConfirmMigrationOnGateway_GatewayToL1_WithSavedBalance() public {
        // First increase chain balance
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: AMOUNT * 2,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });
        vm.prank(INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, CANONICAL_TX_HASH, balanceChange);

        // Mock settlement layer for calculating previous migration number
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, CHAIN_ID),
            abi.encode(block.chainid)
        );

        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(3)
        );

        // Mock getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        // Confirm migration
        TokenBalanceMigrationData memory data = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID,
            amount: AMOUNT,
            assetMigrationNumber: MIGRATION_NUMBER,
            chainMigrationNumber: 0,
            isL1ToGateway: false
        });

        uint256 balanceBefore = gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(data);

        // Verify balance was decreased (lines 624, 630-631)
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), balanceBefore - AMOUNT);
        // Verify token data
        assertEq(gwAssetTracker.getOriginToken(ASSET_ID), ORIGIN_TOKEN);
        assertEq(gwAssetTracker.getTokenOriginChainId(ASSET_ID), ORIGIN_CHAIN_ID);
    }
}
