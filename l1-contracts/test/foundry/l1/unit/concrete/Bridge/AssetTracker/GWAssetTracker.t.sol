// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {MigrationTestBase} from "foundry-test/l1/integration/unit-migration/_SharedMigrationBase.t.sol";
import {GWAssetTracker} from "contracts/bridge/asset-tracker/GWAssetTracker.sol";

import {BalanceChange, MigrationConfirmationData, L2Log} from "contracts/common/Messaging.sol";
import {
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_MESSAGE_ROOT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_ASSET_ROUTER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {BALANCE_CHANGE_VERSION} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";

import {
    InvalidCanonicalTxHash,
    RegisterNewTokenNotAllowed,
    InsufficientPendingInteropBalance,
    InsufficientChainBalance
} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {ChainIdNotRegistered, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {ProcessLogsTestHelper} from "./ProcessLogsTestHelper.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";

import {L2MessageRoot} from "contracts/core/message-root/L2MessageRoot.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";

contract GWAssetTrackerTestHelper is GWAssetTracker {
    constructor() GWAssetTracker() {}
    function getEmptyMultichainBatchRoot(uint256 _chainId) external returns (bytes32) {
        return _getEmptyMultichainBatchRoot(_chainId);
    }

    function getOriginToken(bytes32 _assetId) external view returns (address) {
        return originToken[_assetId];
    }

    function getTokenOriginChainId(bytes32 _assetId) external view returns (uint256) {
        return tokenOriginChainId[_assetId];
    }

    function getLegacySharedBridgeAddress(uint256 _chainId) external view returns (address) {
        return legacySharedBridgeAddress[_chainId];
    }

    /// @notice Helper to set chain balance directly for testing
    function setChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) external {
        chainBalance[_chainId][_assetId] = _amount;
    }

    /// @notice Helper to set pending interop balance directly for testing
    function setPendingInteropBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) external {
        pendingInteropBalance[_chainId][_assetId] = _amount;
    }
}

contract GWAssetTrackerTest is MigrationTestBase {
    GWAssetTrackerTestHelper public gwAssetTracker;
    address public mockBridgehub;
    address public mockMessageRoot;
    address public mockNativeTokenVault;
    address public mockChainAssetHandler;
    address public mockZKChain;
    address public mockDestZKChain;
    address public mockAssetRouter;

    uint256 public constant L1_CHAIN_ID = 1;
    uint256 public constant CHAIN_ID = 2;
    uint256 public constant DEST_CHAIN_ID = 200;
    bytes32 public constant DEST_BASE_TOKEN_ASSET_ID = keccak256("destBaseTokenAssetId");
    uint256 public constant MIGRATION_NUMBER = 10;
    bytes32 public constant ASSET_ID = keccak256("assetId");
    bytes32 public constant CANONICAL_TX_HASH = keccak256("canonicalTxHash");
    address public constant ORIGIN_TOKEN = address(0x123);
    uint256 public constant ORIGIN_CHAIN_ID = 3;
    uint256 public constant AMOUNT = 1000;
    bytes32 public constant BASE_TOKEN_ASSET_ID = keccak256("baseTokenAssetId");
    uint256 public constant BASE_TOKEN_AMOUNT = 500;

    function setUp() public override {
        super.setUp();

        // Deploy GWAssetTrackerTestHelper
        gwAssetTracker = new GWAssetTrackerTestHelper();

        // Create mock addresses
        mockBridgehub = makeAddr("mockBridgehub");
        mockMessageRoot = makeAddr("mockMessageRoot");
        mockNativeTokenVault = makeAddr("mockNativeTokenVault");
        mockChainAssetHandler = makeAddr("mockChainAssetHandler");
        mockZKChain = makeAddr("mockZKChain");
        mockDestZKChain = makeAddr("mockDestZKChain");
        mockAssetRouter = makeAddr("mockAssetRouter");

        // Mock the L2 contract addresses
        vm.etch(L2_BRIDGEHUB_ADDR, address(mockBridgehub).code);
        vm.etch(L2_MESSAGE_ROOT_ADDR, address(mockMessageRoot).code);
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, address(mockNativeTokenVault).code);
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, address(mockChainAssetHandler).code);
        vm.etch(L2_ASSET_ROUTER_ADDR, address(mockAssetRouter).code);

        // Mock the WETH_TOKEN() call on NativeTokenVault
        address mockWrappedZKToken = makeAddr("mockWrappedZKToken");
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.WETH_TOKEN.selector),
            abi.encode(mockWrappedZKToken)
        );

        // Set up the contract
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.initL2(L1_CHAIN_ID, address(this));

        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IChainAssetHandlerBase.migrationNumber.selector),
            abi.encode(1)
        );

        // Wildcard mocks for processLogsAndMessages (any chainId → mockZKChain, any assetId → BASE_TOKEN_ASSET_ID).
        // Specific tests that need different values override these with full-calldata mocks.
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector),
            abi.encode(mockZKChain)
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );
        // Specific mock for DEST_CHAIN_ID
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, DEST_CHAIN_ID),
            abi.encode(mockDestZKChain)
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, DEST_CHAIN_ID),
            abi.encode(DEST_BASE_TOKEN_ASSET_ID)
        );
        // Wildcard mock for addChainBatchRoot (any batch)
        vm.mockCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSignature("addChainBatchRoot(uint256,uint256,bytes32)"),
            abi.encode()
        );
    }

    function test_InitL2() public {
        uint256 newL1ChainId = 999;

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.initL2(newL1ChainId, address(this));

        assertEq(gwAssetTracker.L1_CHAIN_ID(), newL1ChainId);
    }

    function test_InitL2_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        gwAssetTracker.initL2(999, address(this));
    }

    function test_HandleChainBalanceIncreaseOnGateway() public {
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });
        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, CANONICAL_TX_HASH, balanceChange);

        // Check that chain balance was increased
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), AMOUNT);
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), BASE_TOKEN_AMOUNT);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, ASSET_ID), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), 0);

        assertEq(gwAssetTracker.getOriginToken(ASSET_ID), ORIGIN_TOKEN);
        assertEq(gwAssetTracker.getTokenOriginChainId(ASSET_ID), ORIGIN_CHAIN_ID);
    }

    function test_HandleChainBalanceIncreaseOnGateway_Unauthorized() public {
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, CANONICAL_TX_HASH, balanceChange);
    }

    function test_HandleChainBalanceIncreaseOnGateway_InvalidCanonicalTxHash() public {
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        // First call succeeds
        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, CANONICAL_TX_HASH, balanceChange);

        // Second call with same canonical tx hash should fail
        vm.expectRevert(abi.encodeWithSelector(InvalidCanonicalTxHash.selector, CANONICAL_TX_HASH));
        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, CANONICAL_TX_HASH, balanceChange);
    }

    function test_SetLegacySharedBridgeAddress() public {
        address legacyBridge = makeAddr("legacyBridge");

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.setLegacySharedBridgeAddress(CHAIN_ID, legacyBridge);
    }

    function test_SetLegacySharedBridgeAddress_Unauthorized() public {
        address legacyBridge = makeAddr("legacyBridge");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        gwAssetTracker.setLegacySharedBridgeAddress(CHAIN_ID, legacyBridge);
    }

    function test_ConfirmMigrationOnGateway_Unauthorized() public {
        MigrationConfirmationData memory data = MigrationConfirmationData({
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID,
            amount: AMOUNT,
            assetMigrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: false
        });

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        gwAssetTracker.confirmMigrationOnGateway(data);
    }

    function test_ParseInteropCall() public {
        bytes memory callData = abi.encodePacked(
            AssetRouterBase.finalizeDeposit.selector,
            abi.encode(CHAIN_ID, ASSET_ID, abi.encode("transferData"))
        );

        (uint256 fromChainId, bytes32 assetId, bytes memory transferData) = gwAssetTracker.parseInteropCall(callData);

        assertEq(fromChainId, CHAIN_ID);
        assertEq(assetId, ASSET_ID);
        assertEq(transferData, abi.encode("transferData"));
    }

    function test_emptyRootEquivalence() public {
        bytes32 emptyRoot = gwAssetTracker.getEmptyMultichainBatchRoot(CHAIN_ID);

        vm.chainId(CHAIN_ID);
        L2MessageRoot dummyL2MessageRoot = new L2MessageRoot();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        dummyL2MessageRoot.initL2(L1_CHAIN_ID, block.chainid);

        assertEq(dummyL2MessageRoot.getAggregatedRoot(), emptyRoot);
    }

    function test_regression_emptyMultichainBatchRootTreeHeightConsistency() public {
        // Get empty root from GWAssetTracker
        bytes32 gwEmptyRoot = gwAssetTracker.getEmptyMultichainBatchRoot(CHAIN_ID);

        // Create an L2MessageRoot and initialize it the same way it's done in production
        vm.chainId(CHAIN_ID);
        L2MessageRoot l2MessageRoot = new L2MessageRoot();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2MessageRoot.initL2(L1_CHAIN_ID, block.chainid);

        // Get the aggregated root from L2MessageRoot (which uses MessageRootBase initialization)
        bytes32 l2AggregatedRoot = l2MessageRoot.getAggregatedRoot();

        // These must match - if the tree height calculation is wrong in GWAssetTracker,
        // this assertion will fail
        assertEq(
            gwEmptyRoot,
            l2AggregatedRoot,
            "Empty message root from GWAssetTracker must match L2MessageRoot's aggregated root"
        );

        // Verify the roots are not zero (sanity check)
        assertTrue(gwEmptyRoot != bytes32(0), "Empty root should not be zero");
    }

    function test_regression_emptyMultichainBatchRootConsistentAcrossChains() public {
        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = 100;
        chainIds[1] = 200;
        chainIds[2] = 300;

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];

            // Get empty root from GWAssetTracker for this chain
            bytes32 gwEmptyRoot = gwAssetTracker.getEmptyMultichainBatchRoot(chainId);

            // Create an L2MessageRoot and initialize it for this chain
            vm.chainId(chainId);
            L2MessageRoot l2MessageRoot = new L2MessageRoot();
            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            l2MessageRoot.initL2(L1_CHAIN_ID, block.chainid);

            // Get the aggregated root from L2MessageRoot
            bytes32 l2AggregatedRoot = l2MessageRoot.getAggregatedRoot();

            // Verify consistency for each chain
            assertEq(
                gwEmptyRoot,
                l2AggregatedRoot,
                string.concat("Empty root mismatch for chain ID: ", vm.toString(chainId))
            );
        }
    }

    function test_SetLegacySharedBridgeAddressForLocalTesting() public {
        address legacyBridge = makeAddr("legacyBridge");

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setLegacySharedBridgeAddressForLocalTesting(CHAIN_ID, legacyBridge);
    }

    function test_SetLegacySharedBridgeAddressForLocalTesting_Unauthorized() public {
        address legacyBridge = makeAddr("legacyBridge");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        gwAssetTracker.setLegacySharedBridgeAddressForLocalTesting(CHAIN_ID, legacyBridge);
    }

    function test_ConfirmMigrationOnGateway_L1ToGateway() public {
        // First increase chain balance to have something to work with
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });
        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, CANONICAL_TX_HASH, balanceChange);

        uint256 initialBalance = gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID);

        MigrationConfirmationData memory data = MigrationConfirmationData({
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID,
            amount: AMOUNT,
            assetMigrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: true
        });

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(data);

        // When isL1ToGateway is true, balance should increase
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), initialBalance + AMOUNT);
    }

    function test_GetEmptyMultichainBatchRoot_Cached() public {
        // First call calculates and caches
        bytes32 emptyRoot1 = gwAssetTracker.getEmptyMultichainBatchRoot(CHAIN_ID);

        // Second call should return cached value
        bytes32 emptyRoot2 = gwAssetTracker.getEmptyMultichainBatchRoot(CHAIN_ID);

        assertEq(emptyRoot1, emptyRoot2);
    }

    function test_HandleChainBalanceIncreaseOnGateway_ZeroAmounts() public {
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: 0,
            baseTokenAmount: 0,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, CANONICAL_TX_HASH, balanceChange);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), 0);
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, ASSET_ID), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), 0);
    }

    function test_RegisterNewToken_Reverts() public {
        // registerNewToken should always revert on GWAssetTracker
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(RegisterNewTokenNotAllowed.selector);
        gwAssetTracker.registerNewTokenIfNeeded(ASSET_ID, ORIGIN_CHAIN_ID);
    }

    function test_RequestPauseDepositsForChain_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        gwAssetTracker.requestPauseDepositsForChain(CHAIN_ID);
    }

    function test_RequestPauseDepositsForChain_ChainNotRegistered() public {
        // Mock bridgehub to return address(0) for getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(address(0))
        );

        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(abi.encodeWithSelector(ChainIdNotRegistered.selector, CHAIN_ID));
        gwAssetTracker.requestPauseDepositsForChain(CHAIN_ID);
    }

    function test_InitiateGatewayToL1MigrationOnGateway_ChainNotRegistered() public {
        // Mock bridgehub to return address(0) for getZKChain
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(address(0))
        );

        vm.expectRevert(abi.encodeWithSelector(ChainIdNotRegistered.selector, CHAIN_ID));
        gwAssetTracker.initiateGatewayToL1MigrationOnGateway(CHAIN_ID, ASSET_ID);
    }

    function test_L1_CHAIN_ID_Getter() public view {
        assertEq(gwAssetTracker.L1_CHAIN_ID(), L1_CHAIN_ID);
    }

    function testFuzz_InitL2(uint256 _l1ChainId) public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.initL2(_l1ChainId, address(this));

        assertEq(gwAssetTracker.L1_CHAIN_ID(), _l1ChainId);
    }

    function testFuzz_HandleChainBalanceIncreaseOnGateway(uint256 _amount, uint256 _baseTokenAmount) public {
        // Bound to reasonable values to avoid overflow
        _amount = bound(_amount, 0, type(uint128).max);
        _baseTokenAmount = bound(_baseTokenAmount, 0, type(uint128).max);

        bytes32 uniqueTxHash = keccak256(abi.encode(_amount, _baseTokenAmount));

        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: _amount,
            baseTokenAmount: _baseTokenAmount,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, uniqueTxHash, balanceChange);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), _amount);
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), _baseTokenAmount);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, ASSET_ID), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), 0);
    }

    function test_HandleChainBalanceIncreaseOnGateway_DifferentAssetAndBaseToken() public {
        bytes32 assetId = keccak256("asset1");
        bytes32 baseTokenId = keccak256("baseToken1");
        bytes32 txHash = keccak256("txHash1");

        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: assetId,
            baseTokenAssetId: baseTokenId,
            amount: 1000,
            baseTokenAmount: 500,
            originToken: makeAddr("originToken"),
            tokenOriginChainId: 5
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, txHash, balanceChange);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, assetId), 1000);
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, baseTokenId), 500);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, assetId), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, baseTokenId), 0);
    }

    function test_MultipleChainBalanceIncreases() public {
        // Test multiple deposits to the same chain for the same asset
        for (uint256 i = 0; i < 5; i++) {
            bytes32 txHash = keccak256(abi.encode("txHash", i));
            BalanceChange memory balanceChange = BalanceChange({
                version: BALANCE_CHANGE_VERSION,
                assetId: ASSET_ID,
                baseTokenAssetId: BASE_TOKEN_ASSET_ID,
                amount: AMOUNT,
                baseTokenAmount: BASE_TOKEN_AMOUNT,
                originToken: ORIGIN_TOKEN,
                tokenOriginChainId: ORIGIN_CHAIN_ID
            });

            vm.prank(L2_INTEROP_CENTER_ADDR);
            gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, txHash, balanceChange);
        }

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), AMOUNT * 5);
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), BASE_TOKEN_AMOUNT * 5);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, ASSET_ID), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), 0);
    }

    function test_GetEmptyMultichainBatchRoot_DifferentChains() public {
        uint256 chainId1 = 100;
        uint256 chainId2 = 200;

        bytes32 emptyRoot1 = gwAssetTracker.getEmptyMultichainBatchRoot(chainId1);
        bytes32 emptyRoot2 = gwAssetTracker.getEmptyMultichainBatchRoot(chainId2);

        // Different chain IDs should produce different roots
        assertTrue(emptyRoot1 != emptyRoot2);
    }

    function test_SetLegacySharedBridgeAddress_DifferentChains() public {
        address legacyBridge1 = makeAddr("legacyBridge1");
        address legacyBridge2 = makeAddr("legacyBridge2");
        uint256 chainId1 = 100;
        uint256 chainId2 = 200;

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.setLegacySharedBridgeAddress(chainId1, legacyBridge1);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.setLegacySharedBridgeAddress(chainId2, legacyBridge2);
    }

    function testFuzz_SetLegacySharedBridgeAddress(uint256 _chainId, address _legacyBridge) public {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.setLegacySharedBridgeAddress(_chainId, _legacyBridge);
    }

    function test_HandleChainBalanceIncreaseOnGateway_SameAssetAndBaseToken() public {
        // Test when assetId equals baseTokenAssetId
        bytes32 sameAssetId = keccak256("sameAsset");
        bytes32 txHash = keccak256("txHash2");

        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: sameAssetId,
            baseTokenAssetId: sameAssetId, // Same as assetId
            amount: 1000,
            baseTokenAmount: 500,
            originToken: makeAddr("originToken"),
            tokenOriginChainId: 5
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, txHash, balanceChange);

        // Total should be amount + baseTokenAmount since they're the same asset
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, sameAssetId), 1500);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, sameAssetId), 0);
    }

    function test_MultipleChains_DifferentBalances() public {
        uint256 chainId1 = 100;
        uint256 chainId2 = 200;
        bytes32 txHash1 = keccak256("txHash100");
        bytes32 txHash2 = keccak256("txHash200");

        BalanceChange memory balanceChange1 = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: 1000,
            baseTokenAmount: 500,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        BalanceChange memory balanceChange2 = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: 2000,
            baseTokenAmount: 1000,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(chainId1, txHash1, balanceChange1);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(chainId2, txHash2, balanceChange2);

        // Verify each chain has its own balance
        assertEq(gwAssetTracker.chainBalance(chainId1, ASSET_ID), 1000);
        assertEq(gwAssetTracker.chainBalance(chainId2, ASSET_ID), 2000);
        assertEq(gwAssetTracker.pendingInteropBalance(chainId1, ASSET_ID), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(chainId2, ASSET_ID), 0);
    }

    function test_ConfirmMigrationOnGateway_GatewayToL1_NoBalanceChange() public {
        // First set up some balance
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: ASSET_ID,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: AMOUNT * 2,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });
        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, CANONICAL_TX_HASH, balanceChange);

        uint256 initialBalance = gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID);
        assertEq(initialBalance, AMOUNT * 2);

        // Mock settlementLayer for the _calculatePreviousChainMigrationNumber call
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, CHAIN_ID),
            abi.encode(0) // Return 0 to indicate not settled on current chain
        );

        MigrationConfirmationData memory data = MigrationConfirmationData({
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID,
            amount: AMOUNT,
            assetMigrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: false
        });

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(data);

        // For Gateway->L1 confirmations, Gateway state is updated at initiation time,
        // so confirmation should not modify chainBalance.
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), initialBalance);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, ASSET_ID), 0);
    }

    function test_ConfirmMigrationOnGateway_InsufficientBalanceDoesNotRevert() public {
        MigrationConfirmationData memory data = MigrationConfirmationData({
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID,
            amount: AMOUNT,
            assetMigrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: false
        });

        uint256 initialBalance = gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID);
        uint256 initialAssetMigrationNumber = gwAssetTracker.assetMigrationNumber(CHAIN_ID, ASSET_ID);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(data);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), initialBalance);
        assertEq(gwAssetTracker.assetMigrationNumber(CHAIN_ID, ASSET_ID), initialAssetMigrationNumber);
    }

    function test_ParseTokenData() public {
        // Test the parseTokenData function
        // DataEncoding.decodeTokenData expects NEW_ENCODING_VERSION prefix
        bytes memory nameBytes = bytes("TestToken");
        bytes memory symbolBytes = bytes("TST");
        bytes memory decimalsBytes = abi.encode(uint8(18));
        // Properly encode with NEW_ENCODING_VERSION (0x01) prefix
        bytes memory metadata = bytes.concat(
            NEW_ENCODING_VERSION,
            abi.encode(ORIGIN_CHAIN_ID, nameBytes, symbolBytes, decimalsBytes)
        );

        (uint256 tokenOriginalChainId, bytes memory name, bytes memory symbol, bytes memory decimals) = gwAssetTracker
            .parseTokenData(metadata);

        assertEq(tokenOriginalChainId, ORIGIN_CHAIN_ID);
        assertEq(string(name), "TestToken");
        assertEq(string(symbol), "TST");
        // decimals is abi.encode(uint8(18)) which is a 32-byte padded value
        assertEq(abi.decode(decimals, (uint8)), 18);
    }

    function test_HandleChainBalanceIncreaseOnGateway_MultipleAssets() public {
        // Test handling multiple different assets for the same chain
        bytes32 assetId1 = keccak256("asset1");
        bytes32 assetId2 = keccak256("asset2");
        bytes32 txHash1 = keccak256("txHash1");
        bytes32 txHash2 = keccak256("txHash2");

        BalanceChange memory balanceChange1 = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: assetId1,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: 1000,
            baseTokenAmount: 100,
            originToken: makeAddr("token1"),
            tokenOriginChainId: 1
        });

        BalanceChange memory balanceChange2 = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: assetId2,
            baseTokenAssetId: BASE_TOKEN_ASSET_ID,
            amount: 2000,
            baseTokenAmount: 200,
            originToken: makeAddr("token2"),
            tokenOriginChainId: 2
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, txHash1, balanceChange1);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, txHash2, balanceChange2);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, assetId1), 1000);
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, assetId2), 2000);
        // Base token balance should accumulate
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), 300);

        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, assetId1), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, assetId2), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, BASE_TOKEN_ASSET_ID), 0);
    }

    function test_ConfirmMigrationOnGateway_L1ToGateway_ZeroAmount() public {
        MigrationConfirmationData memory data = MigrationConfirmationData({
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID,
            amount: 0,
            assetMigrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: true
        });

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(data);

        // Balance should remain 0
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), 0);
        assertEq(gwAssetTracker.getOriginToken(ASSET_ID), ORIGIN_TOKEN);
        assertEq(gwAssetTracker.getTokenOriginChainId(ASSET_ID), ORIGIN_CHAIN_ID);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, ASSET_ID), 0);
    }

    function testFuzz_ConfirmMigrationOnGateway_L1ToGateway(uint256 _amount) public {
        _amount = bound(_amount, 0, type(uint128).max);

        MigrationConfirmationData memory data = MigrationConfirmationData({
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID,
            amount: _amount,
            assetMigrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: true
        });

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(data);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), _amount);
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, ASSET_ID), 0);
    }

    /// @notice When source chain settles an interop bundle, source chainBalance decreases and
    ///         destination pendingInteropBalance increases (not chainBalance directly).
    ///         After the destination confirms via InteropHandler, pending moves to chainBalance.
    function test_regression_chainBalanceChangeIncreasesDestinationBalance() public {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(ORIGIN_CHAIN_ID, ORIGIN_TOKEN);
        uint256 transferAmount = 1000;

        gwAssetTracker.setChainBalance(CHAIN_ID, assetId, transferAmount * 2);

        uint256 sourceBalanceBefore = gwAssetTracker.chainBalance(CHAIN_ID, assetId);

        // Source chain settles the interop bundle: source chainBalance decreases, dest pending increases.
        _submitInteropBundleWithArCall(CHAIN_ID, DEST_CHAIN_ID, assetId, transferAmount);

        assertEq(
            gwAssetTracker.chainBalance(CHAIN_ID, assetId),
            sourceBalanceBefore - transferAmount,
            "Source chain balance should decrease"
        );
        assertEq(
            gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, assetId),
            transferAmount,
            "Destination pending balance should increase"
        );
        assertEq(
            gwAssetTracker.chainBalance(DEST_CHAIN_ID, assetId),
            0,
            "Destination chainBalance stays 0 until confirmed"
        );

        // Destination chain confirms via InteropHandler: pending moves to chainBalance.
        _confirmInteropAsset(DEST_CHAIN_ID, assetId, transferAmount);

        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, assetId), 0);
        assertEq(
            gwAssetTracker.chainBalance(DEST_CHAIN_ID, assetId),
            transferAmount,
            "Destination chain balance should increase after confirmation"
        );
    }

    /// @notice L2→L1 asset router withdrawals decrease source chainBalance; L1 balance is not tracked.
    function test_regression_l1DestinationNeverIncreases() public {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(ORIGIN_CHAIN_ID, ORIGIN_TOKEN);
        uint256 transferAmount = 1000;

        gwAssetTracker.setChainBalance(CHAIN_ID, assetId, transferAmount * 2);

        uint256 sourceBalanceBefore = gwAssetTracker.chainBalance(CHAIN_ID, assetId);
        uint256 l1BalanceBefore = gwAssetTracker.chainBalance(L1_CHAIN_ID, assetId);

        // Asset router withdrawal message: L2 source → L1 (not tracked on Gateway)
        _submitArWithdrawal(CHAIN_ID, assetId, transferAmount);

        assertEq(
            gwAssetTracker.chainBalance(CHAIN_ID, assetId),
            sourceBalanceBefore - transferAmount,
            "Source chain balance should decrease"
        );
        assertEq(
            gwAssetTracker.chainBalance(L1_CHAIN_ID, assetId),
            l1BalanceBefore,
            "L1 balance should not be tracked on Gateway"
        );
        assertEq(gwAssetTracker.pendingInteropBalance(CHAIN_ID, assetId), 0);
    }

    function testFuzz_regression_chainBalanceChange(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        uint256 _amount
    ) public {
        _sourceChainId = bound(_sourceChainId, 2, 1000);
        _destinationChainId = bound(_destinationChainId, 2, 1000);
        _amount = bound(_amount, 1, type(uint128).max);

        vm.assume(_sourceChainId != _destinationChainId);
        vm.assume(_sourceChainId != L1_CHAIN_ID);
        vm.assume(_destinationChainId != L1_CHAIN_ID);

        bytes32 assetId = DataEncoding.encodeNTVAssetId(ORIGIN_CHAIN_ID, ORIGIN_TOKEN);
        gwAssetTracker.setChainBalance(_sourceChainId, assetId, _amount * 2);

        uint256 sourceBalanceBefore = gwAssetTracker.chainBalance(_sourceChainId, assetId);

        // DEST_CHAIN_ID has a dedicated mock returning mockDestZKChain; all other chains use mockZKChain.
        address srcSender = _sourceChainId == DEST_CHAIN_ID ? mockDestZKChain : mockZKChain;
        address dstSender = _destinationChainId == DEST_CHAIN_ID ? mockDestZKChain : mockZKChain;

        _submitInteropBundleWithArCall(_sourceChainId, srcSender, _destinationChainId, assetId, _amount);

        assertEq(
            gwAssetTracker.chainBalance(_sourceChainId, assetId),
            sourceBalanceBefore - _amount,
            "Source balance should decrease"
        );
        assertEq(
            gwAssetTracker.pendingInteropBalance(_destinationChainId, assetId),
            _amount,
            "Destination pending balance should increase"
        );
        assertEq(
            gwAssetTracker.chainBalance(_destinationChainId, assetId),
            0,
            "Destination chainBalance stays 0 until confirmed"
        );

        _confirmInteropAsset(_destinationChainId, dstSender, assetId, _amount);

        assertEq(gwAssetTracker.pendingInteropBalance(_destinationChainId, assetId), 0);
        assertEq(
            gwAssetTracker.chainBalance(_destinationChainId, assetId),
            _amount,
            "Destination chainBalance after confirmation"
        );
    }

    /// @notice Regression: legacy bridge message decoding does not revert (parseTokenData on empty bytes was fixed).
    function test_regression_legacySharedBridgeMessageDecodingDoesNotFail() public {
        uint256 legacyChainId = 324; // Era chain ID
        address l1Token = makeAddr("l1Token");
        address l1Receiver = makeAddr("l1Receiver");
        uint256 withdrawAmount = 1000;

        address legacyBridge = makeAddr("legacySharedBridge");
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setLegacySharedBridgeAddressForLocalTesting(legacyChainId, legacyBridge);

        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);
        gwAssetTracker.setChainBalance(legacyChainId, assetId, withdrawAmount * 2);

        bytes memory legacyMessage = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            l1Receiver,
            l1Token,
            withdrawAmount
        );

        uint256 balanceBefore = gwAssetTracker.chainBalance(legacyChainId, assetId);

        _submitLegacyBridgeWithdrawal(legacyChainId, legacyBridge, legacyMessage);

        assertEq(
            gwAssetTracker.chainBalance(legacyChainId, assetId),
            balanceBefore - withdrawAmount,
            "Chain balance should decrease after legacy withdrawal"
        );
        assertEq(gwAssetTracker.pendingInteropBalance(legacyChainId, assetId), 0);
    }

    /// @notice Test that the legacy token data is properly encoded with L1 chain ID
    /// @dev Verifies the fix encodes the L1 chain ID in the token metadata
    function test_regression_legacyTokenDataEncodesL1ChainId() public {
        // Test that decodeLegacyFinalizeWithdrawalData produces properly encoded token data
        address l1Token = makeAddr("testToken");
        address l1Receiver = makeAddr("testReceiver");
        uint256 amount = 500;

        // Construct a legacy message
        bytes memory legacyMessage = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            l1Receiver,
            l1Token,
            amount
        );

        // Decode it using the library function
        (bytes4 sig, address token, bytes memory transferData) = DataEncoding.decodeLegacyFinalizeWithdrawalData(
            L1_CHAIN_ID,
            legacyMessage
        );

        assertEq(sig, IL1ERC20Bridge.finalizeWithdrawal.selector, "Function signature mismatch");
        assertEq(token, l1Token, "Token address mismatch");

        // Decode the transfer data to get erc20Metadata
        (, , , , bytes memory erc20Metadata) = DataEncoding.decodeBridgeMintData(transferData);

        // Verify the metadata is not empty and can be parsed
        assertTrue(erc20Metadata.length > 0, "erc20Metadata should not be empty");

        // Parse the token data - this is what was failing before the fix
        (uint256 originChainId, bytes memory name, bytes memory symbol, bytes memory decimals) = gwAssetTracker
            .parseTokenData(erc20Metadata);

        // The origin chain ID should be L1_CHAIN_ID (legacy tokens are L1 tokens)
        assertEq(originChainId, L1_CHAIN_ID, "Origin chain ID should be L1 chain ID");

        // Name, symbol, decimals should be empty but valid
        assertEq(name.length, 0, "Name should be empty");
        assertEq(symbol.length, 0, "Symbol should be empty");
        assertEq(decimals.length, 0, "Decimals should be empty");
    }

    /// @notice Test multiple legacy withdrawals can be processed via processLogsAndMessages.
    function test_regression_multipleLegacyWithdrawalsSucceed() public {
        uint256 legacyChainId = 324;
        address l1Token = makeAddr("l1Token");
        uint256 withdrawAmount = 100;

        address legacyBridge = makeAddr("legacySharedBridge");
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setLegacySharedBridgeAddressForLocalTesting(legacyChainId, legacyBridge);

        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);
        gwAssetTracker.setChainBalance(legacyChainId, assetId, withdrawAmount * 10);

        for (uint256 i = 0; i < 5; i++) {
            address receiver = makeAddr(string(abi.encodePacked("receiver", i)));

            bytes memory legacyMessage = abi.encodePacked(
                IL1ERC20Bridge.finalizeWithdrawal.selector,
                receiver,
                l1Token,
                withdrawAmount
            );

            uint256 balanceBefore = gwAssetTracker.chainBalance(legacyChainId, assetId);

            _submitLegacyBridgeWithdrawal(legacyChainId, legacyBridge, legacyMessage);

            assertEq(
                gwAssetTracker.chainBalance(legacyChainId, assetId),
                balanceBefore - withdrawAmount,
                "Balance should decrease for each withdrawal"
            );
            assertEq(gwAssetTracker.pendingInteropBalance(legacyChainId, assetId), 0);
        }

        assertEq(
            gwAssetTracker.chainBalance(legacyChainId, assetId),
            withdrawAmount * 5,
            "Final balance should reflect all withdrawals"
        );
        assertEq(gwAssetTracker.pendingInteropBalance(legacyChainId, assetId), 0);
    }

    /// @notice Fuzz test: legacy withdrawal message processing via processLogsAndMessages.
    function testFuzz_regression_legacyWithdrawalMessage(
        address _l1Token,
        address _l1Receiver,
        uint256 _amount
    ) public {
        _amount = bound(_amount, 1, type(uint128).max);
        vm.assume(_l1Token != address(0));
        vm.assume(_l1Receiver != address(0));

        uint256 legacyChainId = 324;

        address legacyBridge = makeAddr("legacySharedBridge");
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setLegacySharedBridgeAddressForLocalTesting(legacyChainId, legacyBridge);

        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, _l1Token);
        gwAssetTracker.setChainBalance(legacyChainId, assetId, _amount * 2);

        bytes memory legacyMessage = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            _l1Receiver,
            _l1Token,
            _amount
        );

        uint256 balanceBefore = gwAssetTracker.chainBalance(legacyChainId, assetId);

        _submitLegacyBridgeWithdrawal(legacyChainId, legacyBridge, legacyMessage);

        assertEq(
            gwAssetTracker.chainBalance(legacyChainId, assetId),
            balanceBefore - _amount,
            "Balance should decrease"
        );
        assertEq(gwAssetTracker.pendingInteropBalance(legacyChainId, assetId), 0);
    }

    function test_regression_firstDepositSetsAssetMigrationNumber() public {
        // Use a fresh asset ID that has never been deposited
        bytes32 freshAssetId = keccak256("fresh-asset-for-first-deposit-test");
        bytes32 freshBaseTokenAssetId = keccak256("fresh-base-token-for-first-deposit-test");
        bytes32 freshTxHash = keccak256("fresh-tx-hash-for-first-deposit-test");

        // Verify initial state: chainBalance and assetMigrationNumber are both 0
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, freshAssetId), 0, "Initial chainBalance should be 0");
        assertEq(
            gwAssetTracker.assetMigrationNumber(CHAIN_ID, freshAssetId),
            0,
            "Initial assetMigrationNumber should be 0"
        );
        assertEq(
            gwAssetTracker.chainBalance(CHAIN_ID, freshBaseTokenAssetId),
            0,
            "Initial base token chainBalance should be 0"
        );
        assertEq(
            gwAssetTracker.assetMigrationNumber(CHAIN_ID, freshBaseTokenAssetId),
            0,
            "Initial base token assetMigrationNumber should be 0"
        );

        // Create balance change for first deposit
        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: freshAssetId,
            baseTokenAssetId: freshBaseTokenAssetId,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        // Execute first deposit
        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, freshTxHash, balanceChange);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, freshAssetId), AMOUNT, "Chain balance should be set");
        assertEq(
            gwAssetTracker.chainBalance(CHAIN_ID, freshBaseTokenAssetId),
            BASE_TOKEN_AMOUNT,
            "Base token balance should be set"
        );

        // THE KEY ASSERTION: assetMigrationNumber should have been set by _forceSetAssetMigrationNumber
        // Before the fix, this would be 0 (optimization missed)
        // After the fix, this should be the current chain migration number (1)
        assertEq(
            gwAssetTracker.assetMigrationNumber(CHAIN_ID, freshAssetId),
            1, // Expected: current chain migration number from mock
            "assetMigrationNumber should be set to chain migration number for first deposit"
        );
        assertEq(
            gwAssetTracker.assetMigrationNumber(CHAIN_ID, freshBaseTokenAssetId),
            1, // Expected: current chain migration number from mock
            "Base token assetMigrationNumber should be set for first deposit"
        );
    }

    /// @notice Test that second deposit does NOT change assetMigrationNumber
    /// @dev Verifies the optimization only applies to first deposits (when both chainBalance and assetMigrationNumber are 0)
    function test_regression_secondDepositDoesNotChangeAssetMigrationNumber() public {
        bytes32 freshAssetId = keccak256("asset-for-second-deposit-test");
        bytes32 freshBaseTokenAssetId = keccak256("base-token-for-second-deposit-test");

        // First deposit
        BalanceChange memory firstDeposit = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: freshAssetId,
            baseTokenAssetId: freshBaseTokenAssetId,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, keccak256("first-tx"), firstDeposit);

        // Record migration number after first deposit
        uint256 migrationNumberAfterFirst = gwAssetTracker.assetMigrationNumber(CHAIN_ID, freshAssetId);
        assertEq(migrationNumberAfterFirst, 1, "Migration number should be set after first deposit");

        // Second deposit
        BalanceChange memory secondDeposit = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: freshAssetId,
            baseTokenAssetId: freshBaseTokenAssetId,
            amount: AMOUNT * 2,
            baseTokenAmount: BASE_TOKEN_AMOUNT * 2,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, keccak256("second-tx"), secondDeposit);

        // Migration number should NOT change after second deposit
        // (because chainBalance > 0, so _tokenCanSkipMigrationOnSettlementLayer returns false)
        assertEq(
            gwAssetTracker.assetMigrationNumber(CHAIN_ID, freshAssetId),
            migrationNumberAfterFirst,
            "Migration number should not change after second deposit"
        );

        // Balance should be accumulated
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, freshAssetId), AMOUNT + AMOUNT * 2, "Balance should accumulate");
    }

    /// @notice Test that tokens with non-zero assetMigrationNumber do not get overwritten
    /// @dev Verifies that _tokenCanSkipMigrationOnSettlementLayer correctly checks assetMigrationNumber != 0
    function test_regression_existingMigrationNumberNotOverwritten() public {
        bytes32 freshAssetId = keccak256("asset-with-existing-migration");
        bytes32 freshBaseTokenAssetId = keccak256("base-with-existing-migration");

        // First, do a deposit to set the migration number
        BalanceChange memory firstDeposit = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: freshAssetId,
            baseTokenAssetId: freshBaseTokenAssetId,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, keccak256("setup-tx"), firstDeposit);

        uint256 originalMigrationNumber = gwAssetTracker.assetMigrationNumber(CHAIN_ID, freshAssetId);
        assertEq(originalMigrationNumber, 1, "Setup: migration number should be 1");

        // Now simulate the balance being drained (e.g., through withdrawals)
        // by directly setting it to 0
        gwAssetTracker.setChainBalance(CHAIN_ID, freshAssetId, 0);
        gwAssetTracker.setChainBalance(CHAIN_ID, freshBaseTokenAssetId, 0);

        // Verify balance is 0 but migration number is still set
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, freshAssetId), 0, "Balance should be 0");
        assertEq(gwAssetTracker.assetMigrationNumber(CHAIN_ID, freshAssetId), 1, "Migration number should still be 1");

        // Now do another deposit - migration number should NOT be reset
        // because _tokenCanSkipMigrationOnSettlementLayer requires BOTH conditions:
        // assetMigrationNumber == 0 AND chainBalance == 0
        BalanceChange memory newDeposit = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: freshAssetId,
            baseTokenAssetId: freshBaseTokenAssetId,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, keccak256("new-deposit-tx"), newDeposit);

        // Migration number should remain unchanged (still 1, not reset)
        assertEq(
            gwAssetTracker.assetMigrationNumber(CHAIN_ID, freshAssetId),
            originalMigrationNumber,
            "Migration number should not be overwritten when it's already set"
        );
    }

    /// @notice Fuzz test for first deposit migration optimization
    /// @dev Verifies the fix works for various chain IDs and asset IDs
    function testFuzz_regression_firstDepositMigrationOptimization(
        uint256 _chainId,
        bytes32 _assetId,
        bytes32 _baseTokenAssetId,
        uint256 _amount,
        uint256 _baseTokenAmount
    ) public {
        // Bound inputs
        _chainId = bound(_chainId, 2, 1000);
        _amount = bound(_amount, 1, type(uint128).max);
        _baseTokenAmount = bound(_baseTokenAmount, 1, type(uint128).max);

        // Ensure unique assets
        vm.assume(_assetId != bytes32(0));
        vm.assume(_baseTokenAssetId != bytes32(0));

        // Ensure this is a fresh deposit (chainBalance and assetMigrationNumber are 0)
        vm.assume(gwAssetTracker.chainBalance(_chainId, _assetId) == 0);
        vm.assume(gwAssetTracker.assetMigrationNumber(_chainId, _assetId) == 0);

        bytes32 uniqueTxHash = keccak256(abi.encode(_chainId, _assetId, _amount, block.timestamp));

        BalanceChange memory balanceChange = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: _assetId,
            baseTokenAssetId: _baseTokenAssetId,
            amount: _amount,
            baseTokenAmount: _baseTokenAmount,
            originToken: makeAddr("token"),
            tokenOriginChainId: 1
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(_chainId, uniqueTxHash, balanceChange);

        // After first deposit, assetMigrationNumber should be set (not 0)
        assertTrue(
            gwAssetTracker.assetMigrationNumber(_chainId, _assetId) != 0,
            "assetMigrationNumber should be set after first deposit"
        );

        // Chain balance should be set
        uint256 expectedAmount = _assetId == _baseTokenAssetId ? _amount + _baseTokenAmount : _amount;
        assertEq(
            gwAssetTracker.chainBalance(_chainId, _assetId),
            expectedAmount,
            "chainBalance should match deposit amount"
        );
    }

    /// @notice Test that the optimization triggers for both assetId and baseTokenAssetId independently
    /// @dev Verifies each asset is checked and updated independently
    function test_regression_firstDepositOptimizationIndependentForAssets() public {
        bytes32 assetId1 = keccak256("independent-asset-1");
        bytes32 assetId2 = keccak256("independent-asset-2");

        // First deposit with assetId1 as main asset and assetId2 as base token
        BalanceChange memory deposit1 = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: assetId1,
            baseTokenAssetId: assetId2,
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, keccak256("tx1"), deposit1);

        // Both should have migration numbers set
        assertEq(gwAssetTracker.assetMigrationNumber(CHAIN_ID, assetId1), 1, "assetId1 migration should be set");
        assertEq(gwAssetTracker.assetMigrationNumber(CHAIN_ID, assetId2), 1, "assetId2 migration should be set");

        // Now a new deposit where one asset is new and one is existing
        bytes32 assetId3 = keccak256("independent-asset-3");

        BalanceChange memory deposit2 = BalanceChange({
            version: BALANCE_CHANGE_VERSION,
            assetId: assetId3, // New asset
            baseTokenAssetId: assetId2, // Existing asset (already has migration number)
            amount: AMOUNT,
            baseTokenAmount: BASE_TOKEN_AMOUNT,
            originToken: ORIGIN_TOKEN,
            tokenOriginChainId: ORIGIN_CHAIN_ID
        });

        vm.prank(L2_INTEROP_CENTER_ADDR);
        gwAssetTracker.handleChainBalanceIncreaseOnGateway(CHAIN_ID, keccak256("tx2"), deposit2);

        // New asset should get migration number set
        assertEq(gwAssetTracker.assetMigrationNumber(CHAIN_ID, assetId3), 1, "assetId3 migration should be set");

        // Existing asset's migration number should not change
        assertEq(gwAssetTracker.assetMigrationNumber(CHAIN_ID, assetId2), 1, "assetId2 migration should still be 1");
    }

    /// @notice Confirming more asset than is pending must revert (ported from GWAssetTrackerPendingInteropTest,
    ///         now using processLogsAndMessages directly).
    function test_InteropHandlerMessage_InsufficientPendingAsset_Reverts() public {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(ORIGIN_CHAIN_ID, ORIGIN_TOKEN);
        uint256 assetAmount = AMOUNT;

        gwAssetTracker.setPendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, BASE_TOKEN_AMOUNT);
        // Asset pending is one short.
        gwAssetTracker.setPendingInteropBalance(DEST_CHAIN_ID, assetId, assetAmount - 1);

        ProcessLogsInput memory input = _buildInteropHandlerInput(DEST_CHAIN_ID, assetId, assetAmount);

        vm.prank(mockDestZKChain);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientPendingInteropBalance.selector, DEST_CHAIN_ID, assetId, assetAmount)
        );
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @notice Pending balance accumulates correctly across multiple interop calls in one bundle.
    function test_InteropBundle_AccumulatesPendingAcrossMultipleCalls() public {
        uint256 valuePerCall = 100;
        uint256 numCalls = 3;
        uint256 totalValue = valuePerCall * numCalls;
        gwAssetTracker.setChainBalance(CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, totalValue);

        ProcessLogsInput memory input = ProcessLogsTestHelper.buildBaseTokenBundleInput(
            gwAssetTracker,
            CHAIN_ID,
            DEST_CHAIN_ID,
            DEST_BASE_TOKEN_ASSET_ID,
            numCalls,
            valuePerCall
        );
        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);
        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), totalValue);
        assertEq(gwAssetTracker.chainBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);

        // Confirm each call individually on the destination chain.
        for (uint256 i = 0; i < numCalls; i++) {
            ProcessLogsInput memory confirmInput = ProcessLogsTestHelper.buildBaseTokenHandlerInput(
                gwAssetTracker,
                DEST_CHAIN_ID,
                DEST_BASE_TOKEN_ASSET_ID,
                valuePerCall
            );
            vm.prank(mockDestZKChain);
            gwAssetTracker.processLogsAndMessages(confirmInput);

            assertEq(
                gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID),
                totalValue - (i + 1) * valuePerCall
            );
            assertEq(gwAssetTracker.chainBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), (i + 1) * valuePerCall);
        }
    }

    /// @notice Source chain lacking sufficient balance for an interop bundle must revert.
    function test_InteropBundle_InsufficientSourceBalance_Reverts() public {
        gwAssetTracker.setChainBalance(CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, BASE_TOKEN_AMOUNT - 1);

        ProcessLogsInput memory input = ProcessLogsTestHelper.buildBaseTokenBundleInput(
            gwAssetTracker,
            CHAIN_ID,
            DEST_CHAIN_ID,
            DEST_BASE_TOKEN_ASSET_ID,
            1,
            BASE_TOKEN_AMOUNT
        );
        vm.prank(mockZKChain);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientChainBalance.selector,
                CHAIN_ID,
                DEST_BASE_TOKEN_ASSET_ID,
                BASE_TOKEN_AMOUNT
            )
        );
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @notice A base-token-only InteropHandler confirmation moves pending → chainBalance.
    function test_InteropHandlerMessage_BaseTokenOnly_ConfirmsBalance() public {
        gwAssetTracker.setPendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID, BASE_TOKEN_AMOUNT);

        ProcessLogsInput memory input = ProcessLogsTestHelper.buildBaseTokenHandlerInput(
            gwAssetTracker,
            DEST_CHAIN_ID,
            DEST_BASE_TOKEN_ASSET_ID,
            BASE_TOKEN_AMOUNT
        );
        vm.prank(mockDestZKChain);
        gwAssetTracker.processLogsAndMessages(input);

        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), 0);
        assertEq(gwAssetTracker.chainBalance(DEST_CHAIN_ID, DEST_BASE_TOKEN_ASSET_ID), BASE_TOKEN_AMOUNT);
        assertEq(gwAssetTracker.pendingInteropBalance(DEST_CHAIN_ID, ASSET_ID), 0);
    }

    // =========================================================================
    //  Helpers
    // =========================================================================

    /// @dev Builds a ProcessLogsInput for the source chain settling an interop bundle with one AR call.
    function _buildInteropBundleInput(
        uint256 _srcChainId,
        uint256 _dstChainId,
        bytes32 _assetId,
        uint256 _amount
    ) internal returns (ProcessLogsInput memory) {
        return
            ProcessLogsTestHelper.buildInteropBundleInput(
                gwAssetTracker,
                _srcChainId,
                _dstChainId,
                DEST_BASE_TOKEN_ASSET_ID,
                _assetId,
                ORIGIN_CHAIN_ID,
                ORIGIN_TOKEN,
                _amount
            );
    }

    /// @dev Builds and submits an interop bundle with one AR call; _srcSender is the pranked ZKChain address.
    function _submitInteropBundleWithArCall(
        uint256 _srcChainId,
        address _srcSender,
        uint256 _dstChainId,
        bytes32 _assetId,
        uint256 _amount
    ) internal {
        ProcessLogsInput memory input = _buildInteropBundleInput(_srcChainId, _dstChainId, _assetId, _amount);
        vm.prank(_srcSender);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @dev Convenience: source uses the wildcard-mock ZKChain (works for any chain except DEST_CHAIN_ID).
    function _submitInteropBundleWithArCall(
        uint256 _srcChainId,
        uint256 _dstChainId,
        bytes32 _assetId,
        uint256 _amount
    ) internal {
        _submitInteropBundleWithArCall(_srcChainId, mockZKChain, _dstChainId, _assetId, _amount);
    }

    /// @dev Builds a ProcessLogsInput for the destination chain confirming one AR-call execution.
    function _buildInteropHandlerInput(
        uint256 _dstChainId,
        bytes32 _assetId,
        uint256 _amount
    ) internal returns (ProcessLogsInput memory) {
        return
            ProcessLogsTestHelper.buildInteropHandlerInput(
                gwAssetTracker,
                _dstChainId,
                DEST_BASE_TOKEN_ASSET_ID,
                _assetId,
                CHAIN_ID,
                ORIGIN_CHAIN_ID,
                ORIGIN_TOKEN,
                _amount
            );
    }

    /// @dev Confirms pending interop asset on _dstChainId; _dstSender is the pranked ZKChain address.
    function _confirmInteropAsset(uint256 _dstChainId, address _dstSender, bytes32 _assetId, uint256 _amount) internal {
        ProcessLogsInput memory input = _buildInteropHandlerInput(_dstChainId, _assetId, _amount);
        vm.prank(_dstSender);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @dev Convenience: dest=DEST_CHAIN_ID with mockDestZKChain sender.
    function _confirmInteropAsset(uint256 _dstChainId, bytes32 _assetId, uint256 _amount) internal {
        _confirmInteropAsset(_dstChainId, mockDestZKChain, _assetId, _amount);
    }

    /// @dev Submits an asset router withdrawal (L2→L1) for the given source chain via processLogsAndMessages.
    function _submitArWithdrawal(uint256 _srcChainId, bytes32 _assetId, uint256 _amount) internal {
        bytes memory withdrawalMsg = DataEncoding.encodeAssetRouterFinalizeDepositData(
            _srcChainId,
            _assetId,
            ProcessLogsTestHelper.buildTransferData(ORIGIN_CHAIN_ID, ORIGIN_TOKEN, _amount)
        );
        L2Log[] memory logs = new L2Log[](1);
        logs[0] = ProcessLogsTestHelper.createAssetRouterWithdrawalLog(0, withdrawalMsg);
        bytes[] memory messages = new bytes[](1);
        messages[0] = withdrawalMsg;
        ProcessLogsInput memory input = ProcessLogsTestHelper.buildProcessLogsInput(
            gwAssetTracker,
            _srcChainId,
            1,
            logs,
            messages,
            address(0)
        );
        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }

    /// @dev Submits a legacy bridge withdrawal for the given chain via processLogsAndMessages.
    function _submitLegacyBridgeWithdrawal(uint256 _chainId, address _legacyBridge, bytes memory _legacyMsg) internal {
        L2Log[] memory logs = new L2Log[](1);
        logs[0] = ProcessLogsTestHelper.createLegacyBridgeLog(0, _legacyBridge, _legacyMsg);
        bytes[] memory messages = new bytes[](1);
        messages[0] = _legacyMsg;
        ProcessLogsInput memory input = ProcessLogsTestHelper.buildProcessLogsInput(
            gwAssetTracker,
            _chainId,
            1,
            logs,
            messages,
            address(0)
        );
        vm.prank(mockZKChain);
        gwAssetTracker.processLogsAndMessages(input);
    }
}
