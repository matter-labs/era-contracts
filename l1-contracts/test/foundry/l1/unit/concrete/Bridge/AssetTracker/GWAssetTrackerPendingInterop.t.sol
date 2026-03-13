// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {
    InteropBundle,
    InteropCall,
    InteropCallExecutedMessage,
    L2Log,
    INTEROP_CALL_VERSION
} from "contracts/common/Messaging.sol";
import {
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_MESSAGE_ROOT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_ASSET_ROUTER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {InsufficientPendingInteropBalance} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {InsufficientChainBalance} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";

import {GWAssetTrackerTestHelper} from "./GWAssetTracker.t.sol";
import {ProcessLogsTestHelper} from "./ProcessLogsTestHelper.sol";

/// @notice Tests for the pendingInteropBalance system:
///   - When a source chain settles with an interop bundle, the destination chain's
///     pendingInteropBalance is increased (not chainBalance directly).
///   - When a destination chain settles and emits InteropHandler messages, those
///     confirmed calls move balance from pendingInteropBalance to chainBalance.
contract GWAssetTrackerPendingInteropTest is Test {
    GWAssetTrackerTestHelper public gwAssetTracker;

    address public mockBridgehub;
    address public mockMessageRoot;
    address public mockNativeTokenVault;
    address public mockChainAssetHandler;
    address public mockSourceZKChain;
    address public mockDestZKChain;
    address public mockAssetRouter;

    uint256 public constant L1_CHAIN_ID = 1;
    uint256 public constant SOURCE_CHAIN_ID = 2;
    uint256 public constant DEST_CHAIN_ID = 300;
    bytes32 public constant SOURCE_BASE_TOKEN_ASSET_ID = keccak256("sourceBaseTokenAssetId");
    bytes32 public constant DEST_BASE_TOKEN_ASSET_ID = keccak256("destBaseTokenAssetId");
    bytes32 public constant ASSET_ID = keccak256("assetId");
    address public constant ORIGIN_TOKEN = address(0x123);
    uint256 public constant ORIGIN_CHAIN_ID = 3;
    uint256 public constant BASE_TOKEN_AMOUNT = 500;
    uint256 public constant ASSET_AMOUNT = 1000;

    function setUp() public {
        gwAssetTracker = new GWAssetTrackerTestHelper();

        mockBridgehub = makeAddr("mockBridgehub");
        mockMessageRoot = makeAddr("mockMessageRoot");
        mockNativeTokenVault = makeAddr("mockNativeTokenVault");
        mockChainAssetHandler = makeAddr("mockChainAssetHandler");
        mockSourceZKChain = makeAddr("mockSourceZKChain");
        mockDestZKChain = makeAddr("mockDestZKChain");
        mockAssetRouter = makeAddr("mockAssetRouter");

        vm.etch(L2_BRIDGEHUB_ADDR, address(mockBridgehub).code);
        vm.etch(L2_MESSAGE_ROOT_ADDR, address(mockMessageRoot).code);
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, address(mockNativeTokenVault).code);
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, address(mockChainAssetHandler).code);
        vm.etch(L2_ASSET_ROUTER_ADDR, address(mockAssetRouter).code);

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.WETH_TOKEN.selector),
            abi.encode(makeAddr("wrappedZKToken"))
        );
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.initL2(L1_CHAIN_ID, address(this));

        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IChainAssetHandlerBase.migrationNumber.selector),
            abi.encode(1)
        );

        // Persistent mocks for processLogsAndMessages calls from both chains.
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, SOURCE_CHAIN_ID),
            abi.encode(mockSourceZKChain)
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, DEST_CHAIN_ID),
            abi.encode(mockDestZKChain)
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, SOURCE_CHAIN_ID),
            abi.encode(SOURCE_BASE_TOKEN_ASSET_ID)
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, DEST_CHAIN_ID),
            abi.encode(DEST_BASE_TOKEN_ASSET_ID)
        );
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)"),
            abi.encode()
        );
    }

    // =========================================================================
    //  Helpers
    // =========================================================================

    /// @dev Builds a ProcessLogsInput for the source chain containing a single interop bundle
    ///      whose calls each carry _valuePerCall base-token value (no asset-router calls).
    function _buildSourceBundleInput(
        uint256 _numCalls,
        uint256 _valuePerCall
    ) internal returns (ProcessLogsInput memory) {
        InteropBundle memory bundle = ProcessLogsTestHelper.createInteropBundleWithBaseTokenValue(
            SOURCE_CHAIN_ID,
            DEST_CHAIN_ID,
            DEST_BASE_TOKEN_ASSET_ID,
            _numCalls,
            _valuePerCall,
            keccak256("salt")
        );
        bytes memory message = ProcessLogsTestHelper.encodeInteropCenterMessage(bundle);
        L2Log[] memory logs = new L2Log[](1);
        logs[0] = ProcessLogsTestHelper.createInteropCenterLog(0, message);
        bytes[] memory messages = new bytes[](1);
        messages[0] = message;
        return ProcessLogsTestHelper.buildProcessLogsInput(gwAssetTracker, SOURCE_CHAIN_ID, 1, logs, messages, address(0));
    }

    /// @dev Builds and submits a processLogsAndMessages call for the source chain
    ///      containing a single interop bundle whose calls each carry _valuePerCall
    ///      base-token value (no asset-router calls).
    function _processSourceBundleWithValue(uint256 _numCalls, uint256 _valuePerCall) internal {
        ProcessLogsInput memory input = _buildSourceBundleInput(_numCalls, _valuePerCall);
        vm.prank(mockSourceZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @dev Builds a ProcessLogsInput for the destination chain containing a single
    ///      InteropHandler confirmation message.
    function _buildDestHandlerInput(bytes memory _handlerMessage) internal returns (ProcessLogsInput memory) {
        L2Log[] memory logs = new L2Log[](1);
        logs[0] = ProcessLogsTestHelper.createInteropHandlerLog(0, _handlerMessage);
        bytes[] memory messages = new bytes[](1);
        messages[0] = _handlerMessage;
        return ProcessLogsTestHelper.buildProcessLogsInput(gwAssetTracker, DEST_CHAIN_ID, 1, logs, messages, address(0));
    }

    /// @dev Builds and submits a processLogsAndMessages call for the destination chain
    ///      containing a single InteropHandler confirmation message.
    function _processDestHandlerMessage(bytes memory _handlerMessage) internal {
        ProcessLogsInput memory input = _buildDestHandlerInput(_handlerMessage);
        vm.prank(mockDestZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @dev Encodes a valid asset-router interop call targeting the given asset.
    ///      Uses ORIGIN_CHAIN_ID / ORIGIN_TOKEN / ASSET_AMOUNT by default.
    function _buildAssetRouterCallData(bytes32 _assetId, uint256 _fromChainId) internal pure returns (bytes memory) {
        bytes memory erc20Metadata = DataEncoding.encodeTokenData(
            ORIGIN_CHAIN_ID,
            abi.encode("TestToken"),
            abi.encode("TT"),
            abi.encode(uint8(18))
        );
        bytes memory transferData = abi.encode(address(0), address(0xdead), ORIGIN_TOKEN, ASSET_AMOUNT, erc20Metadata);
        return
            abi.encodePacked(
                AssetRouterBase.finalizeDeposit.selector,
                abi.encode(_fromChainId, _assetId, transferData)
            );
    }

    // =========================================================================
    //  Bundle processing: source chain settling increases destination PENDING
    // =========================================================================

    // When a source chain settles with an interop bundle:
    //   - destination pendingInteropBalance increases (not chainBalance)
    //   - source chainBalance decreases
    function test_InteropBundle_UpdatesSourceAndDestinationBalances() public {
        uint256 totalValue = BASE_TOKEN_AMOUNT;
        gwAssetTracker.setChainBalance(SOURCE_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, totalValue);

        _processSourceBundleWithValue(1, totalValue);

        assertEq(gwAssetTracker.chainBalance(SOURCE_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), totalValue);
        assertEq(gwAssetTracker.chainBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);
    }

    // Pending balance accumulates correctly across multiple calls in one bundle.
    function test_InteropBundle_AccumulatesPendingAcrossMultipleCalls() public {
        uint256 valuePerCall = 100;
        uint256 numCalls = 3;
        uint256 totalValue = valuePerCall * numCalls;
        gwAssetTracker.setChainBalance(SOURCE_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, totalValue);

        _processSourceBundleWithValue(numCalls, valuePerCall);

        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), totalValue);
    }

    // Attempting to process a bundle when the source chain lacks sufficient balance reverts.
    function test_InteropBundle_InsufficientSourceBalance_Reverts() public {
        // Source chain has less than the bundle requires.
        gwAssetTracker.setChainBalance(SOURCE_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, BASE_TOKEN_AMOUNT - 1);

        ProcessLogsInput memory input = _buildSourceBundleInput(1, BASE_TOKEN_AMOUNT);
        vm.prank(mockSourceZKChain);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientChainBalance.selector,
                SOURCE_CHAIN_ID,
                DEST_BASE_TOKEN_ASSET_ID,
                BASE_TOKEN_AMOUNT
            )
        );
        gwAssetTracker.processLogsAndMessages(input);
    }

    // =========================================================================
    //  InteropHandler messages: destination chain confirms pending → chain
    // =========================================================================

    // A valid receiveInteropCallExecuted message with a non-AR call:
    //   - base token moves from pendingInteropBalance to chainBalance
    //   - asset pending balance is not touched
    function test_InteropHandlerMessage_BaseTokenOnly_ConfirmsBalance() public {
        gwAssetTracker.setPendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, BASE_TOKEN_AMOUNT);

        InteropCall memory interopCall = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: address(0xdead),
            from: address(1), // not L2_ASSET_ROUTER_ADDR
            value: BASE_TOKEN_AMOUNT,
            data: ""
        });
        InteropCallExecutedMessage memory executionMsg = InteropCallExecutedMessage({
            destinationBaseTokenAssetId: DEST_BASE_TOKEN_ASSET_ID,
            interopCall: interopCall
        });
        bytes memory handlerMsg = ProcessLogsTestHelper.encodeInteropCallExecutedMessage(executionMsg);

        _processDestHandlerMessage(handlerMsg);

        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);
        assertEq(gwAssetTracker.chainBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), BASE_TOKEN_AMOUNT);
        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, ASSET_ID), 0);
    }

    // A call with value == 0 should not touch the base-token pending balance.
    function test_InteropHandlerMessage_ZeroValue_SkipsBaseToken() public {
        InteropCall memory interopCall = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: address(0xdead),
            from: address(1),
            value: 0,
            data: ""
        });
        InteropCallExecutedMessage memory executionMsg = InteropCallExecutedMessage({
            destinationBaseTokenAssetId: DEST_BASE_TOKEN_ASSET_ID,
            interopCall: interopCall
        });
        bytes memory handlerMsg = ProcessLogsTestHelper.encodeInteropCallExecutedMessage(executionMsg);

        // No pending balance set — would revert if the code tried to confirm anything.
        _processDestHandlerMessage(handlerMsg);

        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);
        assertEq(gwAssetTracker.chainBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);
    }

    // An asset-router call moves both the base token and the asset from pending to chain.
    function test_InteropHandlerMessage_AssetRouterCall_ConfirmsBothBalances() public {
        bytes32 computedAssetId = DataEncoding.encodeNTVAssetId(ORIGIN_CHAIN_ID, ORIGIN_TOKEN);

        gwAssetTracker.setPendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, BASE_TOKEN_AMOUNT);
        gwAssetTracker.setPendingInteropBalance(DEST_CHAIN_ID, computedAssetId, ASSET_AMOUNT);

        bytes memory callData = _buildAssetRouterCallData(computedAssetId, SOURCE_CHAIN_ID);
        InteropCall memory interopCall = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: L2_ASSET_ROUTER_ADDR,
            from: L2_ASSET_ROUTER_ADDR,
            value: BASE_TOKEN_AMOUNT,
            data: callData
        });
        InteropCallExecutedMessage memory executionMsg = InteropCallExecutedMessage({
            destinationBaseTokenAssetId: DEST_BASE_TOKEN_ASSET_ID,
            interopCall: interopCall
        });
        bytes memory handlerMsg = ProcessLogsTestHelper.encodeInteropCallExecutedMessage(executionMsg);

        _processDestHandlerMessage(handlerMsg);

        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);
        assertEq(gwAssetTracker.chainBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), BASE_TOKEN_AMOUNT);
        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, computedAssetId), 0);
        assertEq(gwAssetTracker.chainBalance(DEST_CHAIN_ID, computedAssetId), ASSET_AMOUNT);
    }

    // Confirming more base-token than is pending must revert.
    function test_InteropHandlerMessage_InsufficientPendingBaseToken_Reverts() public {
        gwAssetTracker.setPendingInteropBalance(
            DEST_CHAIN_ID,
            DEST_BASE_TOKEN_ASSET_ID,
            BASE_TOKEN_AMOUNT - 1 // one short
        );

        InteropCall memory interopCall = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: address(0xdead),
            from: address(1),
            value: BASE_TOKEN_AMOUNT,
            data: ""
        });
        InteropCallExecutedMessage memory executionMsg = InteropCallExecutedMessage({
            destinationBaseTokenAssetId: DEST_BASE_TOKEN_ASSET_ID,
            interopCall: interopCall
        });
        bytes memory handlerMsg = ProcessLogsTestHelper.encodeInteropCallExecutedMessage(executionMsg);

        ProcessLogsInput memory input = _buildDestHandlerInput(handlerMsg);
        vm.prank(mockDestZKChain);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientPendingInteropBalance.selector,
                DEST_CHAIN_ID,
                DEST_BASE_TOKEN_ASSET_ID,
                BASE_TOKEN_AMOUNT
            )
        );
        gwAssetTracker.processLogsAndMessages(input);
    }

    // Confirming more asset than is pending must revert.
    function test_InteropHandlerMessage_InsufficientPendingAsset_Reverts() public {
        bytes32 computedAssetId = DataEncoding.encodeNTVAssetId(ORIGIN_CHAIN_ID, ORIGIN_TOKEN);

        gwAssetTracker.setPendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, BASE_TOKEN_AMOUNT);
        // Asset pending is less than ASSET_AMOUNT.
        gwAssetTracker.setPendingInteropBalance(DEST_CHAIN_ID, computedAssetId, ASSET_AMOUNT - 1);

        bytes memory callData = _buildAssetRouterCallData(computedAssetId, SOURCE_CHAIN_ID);
        InteropCall memory interopCall = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: L2_ASSET_ROUTER_ADDR,
            from: L2_ASSET_ROUTER_ADDR,
            value: BASE_TOKEN_AMOUNT,
            data: callData
        });
        InteropCallExecutedMessage memory executionMsg = InteropCallExecutedMessage({
            destinationBaseTokenAssetId: DEST_BASE_TOKEN_ASSET_ID,
            interopCall: interopCall
        });
        bytes memory handlerMsg = ProcessLogsTestHelper.encodeInteropCallExecutedMessage(executionMsg);

        ProcessLogsInput memory input = _buildDestHandlerInput(handlerMsg);
        vm.prank(mockDestZKChain);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientPendingInteropBalance.selector,
                DEST_CHAIN_ID,
                computedAssetId,
                ASSET_AMOUNT
            )
        );
        gwAssetTracker.processLogsAndMessages(input);
    }

    // =========================================================================
    //  Full end-to-end flow
    // =========================================================================

    // Source chain settles (bundle → pending), then destination chain settles
    // (InteropHandler message → chainBalance).  After both steps, chainBalance
    // on the destination must equal the original value and pending must be zero.
    function test_FullInteropFlow_PendingToConfirmed() public {
        uint256 totalValue = BASE_TOKEN_AMOUNT;

        // Step 1: source chain settles; destination gets pending balance.
        gwAssetTracker.setChainBalance(SOURCE_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, totalValue);
        _processSourceBundleWithValue(1, totalValue);

        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), totalValue);
        assertEq(gwAssetTracker.chainBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);

        // Step 2: destination chain settles; InteropHandler confirms execution.
        InteropCall memory interopCall = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: address(0xdead),
            from: address(1),
            value: totalValue,
            data: ""
        });
        InteropCallExecutedMessage memory executionMsg = InteropCallExecutedMessage({
            destinationBaseTokenAssetId: DEST_BASE_TOKEN_ASSET_ID,
            interopCall: interopCall
        });
        bytes memory handlerMsg = ProcessLogsTestHelper.encodeInteropCallExecutedMessage(executionMsg);
        _processDestHandlerMessage(handlerMsg);

        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);
        assertEq(gwAssetTracker.chainBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), totalValue);
    }
}
