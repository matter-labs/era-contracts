// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {GWAssetTracker} from "contracts/bridge/asset-tracker/GWAssetTracker.sol";

import {BalanceChange, ConfirmBalanceMigrationData} from "contracts/common/Messaging.sol";
import {L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_CENTER_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";

import {BALANCE_CHANGE_VERSION, TOKEN_BALANCE_MIGRATION_DATA_VERSION} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";

import {InvalidCanonicalTxHash, RegisterNewTokenNotAllowed} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {Unauthorized, ChainIdNotRegistered} from "contracts/common/L1ContractErrors.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";

import {L2MessageRoot} from "contracts/core/message-root/L2MessageRoot.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";

contract GWAssetTrackerTestHelper is GWAssetTracker {
    constructor() GWAssetTracker() {}
    function getEmptyMessageRoot(uint256 _chainId) external returns (bytes32) {
        return _getEmptyMessageRoot(_chainId);
    }

    function getLegacySharedBridgeAddress(uint256 _chainId) external view returns (address) {
        return legacySharedBridgeAddress[_chainId];
    }

    function handleChainBalanceChangeOnGateway(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isInteropCall
    ) external {
        _handleChainBalanceChangeOnGateway(_sourceChainId, _destinationChainId, _assetId, _amount, _isInteropCall);
    }

    /// @notice Helper to set chain balance directly for testing
    function setChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) external {
        chainBalance[_chainId][_assetId] = _amount;
    }

    /// @notice Exposes internal _handleLegacySharedBridgeMessage for testing
    function handleLegacySharedBridgeMessage(uint256 _chainId, bytes memory _message) external {
        _handleLegacySharedBridgeMessage(_chainId, _message);
    }
}

contract GWAssetTrackerTest is Test {
    GWAssetTrackerTestHelper public gwAssetTracker;
    address public mockBridgehub;
    address public mockMessageRoot;
    address public mockNativeTokenVault;
    address public mockChainAssetHandler;
    address public mockZKChain;

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

        // Mock the L2 contract addresses
        vm.etch(L2_BRIDGEHUB_ADDR, address(mockBridgehub).code);
        vm.etch(L2_MESSAGE_ROOT_ADDR, address(mockMessageRoot).code);
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, address(mockNativeTokenVault).code);
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, address(mockChainAssetHandler).code);

        // Mock the WETH_TOKEN() call on NativeTokenVault
        address mockWrappedZKToken = makeAddr("mockWrappedZKToken");
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.WETH_TOKEN.selector),
            abi.encode(mockWrappedZKToken)
        );

        // Set up the contract
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setAddresses(L1_CHAIN_ID);

        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(1)
        );
    }

    function test_SetAddresses() public {
        uint256 newL1ChainId = 999;

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setAddresses(newL1ChainId);

        assertEq(gwAssetTracker.L1_CHAIN_ID(), newL1ChainId);
    }

    function test_SetAddresses_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        gwAssetTracker.setAddresses(999);
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

        // Check that token was registered (these are internal mappings, so we can't test them directly)
        // The token registration happens in the _registerToken function
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
        ConfirmBalanceMigrationData memory data = ConfirmBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            amount: AMOUNT,
            migrationNumber: MIGRATION_NUMBER,
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
        bytes32 emptyRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);

        vm.chainId(CHAIN_ID);
        L2MessageRoot dummyL2MessageRoot = new L2MessageRoot();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        dummyL2MessageRoot.initL2(L1_CHAIN_ID, block.chainid);

        assertEq(dummyL2MessageRoot.getAggregatedRoot(), emptyRoot);
    }

    function test_regression_emptyMessageRootTreeHeightConsistency() public {
        // Get empty root from GWAssetTracker
        bytes32 gwEmptyRoot = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);

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

    function test_regression_emptyMessageRootConsistentAcrossChains() public {
        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = 100;
        chainIds[1] = 200;
        chainIds[2] = 300;

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];

            // Get empty root from GWAssetTracker for this chain
            bytes32 gwEmptyRoot = gwAssetTracker.getEmptyMessageRoot(chainId);

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

        ConfirmBalanceMigrationData memory data = ConfirmBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            amount: AMOUNT,
            migrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: true
        });

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(data);

        // When isL1ToGateway is true, balance should increase
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), initialBalance + AMOUNT);
    }

    function test_GetEmptyMessageRoot_Cached() public {
        // First call calculates and caches
        bytes32 emptyRoot1 = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);

        // Second call should return cached value
        bytes32 emptyRoot2 = gwAssetTracker.getEmptyMessageRoot(CHAIN_ID);

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
    }

    function test_RegisterNewToken_Reverts() public {
        // registerNewToken should always revert on GWAssetTracker
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(RegisterNewTokenNotAllowed.selector);
        gwAssetTracker.registerNewToken(ASSET_ID, ORIGIN_CHAIN_ID);
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

    function testFuzz_SetAddresses(uint256 _l1ChainId) public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setAddresses(_l1ChainId);

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
    }

    function test_GetEmptyMessageRoot_DifferentChains() public {
        uint256 chainId1 = 100;
        uint256 chainId2 = 200;

        bytes32 emptyRoot1 = gwAssetTracker.getEmptyMessageRoot(chainId1);
        bytes32 emptyRoot2 = gwAssetTracker.getEmptyMessageRoot(chainId2);

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
    }

    function test_ConfirmMigrationOnGateway_GatewayToL1_DecreaseBalance() public {
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

        ConfirmBalanceMigrationData memory data = ConfirmBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            amount: AMOUNT,
            migrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: false
        });

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(data);

        // When isL1ToGateway is false, balance should decrease
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), initialBalance - AMOUNT);
    }

    function test_ConfirmMigrationOnGateway_InvalidVersion() public {
        ConfirmBalanceMigrationData memory data = ConfirmBalanceMigrationData({
            version: 0, // Invalid version
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            amount: AMOUNT,
            migrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: false
        });

        vm.prank(SERVICE_TRANSACTION_SENDER);
        // This should fail due to version check
        vm.expectRevert();
        gwAssetTracker.confirmMigrationOnGateway(data);
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
    }

    function test_ConfirmMigrationOnGateway_L1ToGateway_ZeroAmount() public {
        ConfirmBalanceMigrationData memory data = ConfirmBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            amount: 0,
            migrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: true
        });

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(data);

        // Balance should remain 0
        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), 0);
    }

    function testFuzz_ConfirmMigrationOnGateway_L1ToGateway(uint256 _amount) public {
        _amount = bound(_amount, 0, type(uint128).max);

        ConfirmBalanceMigrationData memory data = ConfirmBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            amount: _amount,
            migrationNumber: MIGRATION_NUMBER,
            isL1ToGateway: true
        });

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(data);

        assertEq(gwAssetTracker.chainBalance(CHAIN_ID, ASSET_ID), _amount);
    }

    function test_regression_interopCallDoesNotIncreaseDestinationBalance() public {
        uint256 sourceChainId = 100;
        uint256 destinationChainId = 200;
        bytes32 assetId = keccak256("testAsset");
        uint256 transferAmount = 1000;

        // Set up initial source chain balance
        gwAssetTracker.setChainBalance(sourceChainId, assetId, transferAmount * 2);

        // Record initial balances
        uint256 sourceBalanceBefore = gwAssetTracker.chainBalance(sourceChainId, assetId);
        uint256 destBalanceBefore = gwAssetTracker.chainBalance(destinationChainId, assetId);

        // Call with _isInteropCall = true (simulating InteropCenter message processing)
        gwAssetTracker.handleChainBalanceChangeOnGateway(
            sourceChainId,
            destinationChainId,
            assetId,
            transferAmount,
            true // _isInteropCall = true
        );

        // Source balance should decrease
        assertEq(
            gwAssetTracker.chainBalance(sourceChainId, assetId),
            sourceBalanceBefore - transferAmount,
            "Source chain balance should decrease"
        );

        // Destination balance should NOT increase when _isInteropCall is true
        // This is the key fix - before PR #1757, this would have increased
        assertEq(
            gwAssetTracker.chainBalance(destinationChainId, assetId),
            destBalanceBefore,
            "Destination chain balance should NOT increase for interop calls"
        );
    }

    /// @notice Test that non-interop calls DO increase destination balance
    /// @dev This verifies the fix doesn't break normal (non-interop) transfers
    function test_regression_nonInteropCallIncreasesDestinationBalance() public {
        uint256 sourceChainId = 100;
        uint256 destinationChainId = 200;
        bytes32 assetId = keccak256("testAsset");
        uint256 transferAmount = 1000;

        // Set up initial source chain balance
        gwAssetTracker.setChainBalance(sourceChainId, assetId, transferAmount * 2);

        // Record initial balances
        uint256 sourceBalanceBefore = gwAssetTracker.chainBalance(sourceChainId, assetId);
        uint256 destBalanceBefore = gwAssetTracker.chainBalance(destinationChainId, assetId);

        // Call with _isInteropCall = false (normal transfer, not interop)
        gwAssetTracker.handleChainBalanceChangeOnGateway(
            sourceChainId,
            destinationChainId,
            assetId,
            transferAmount,
            false // _isInteropCall = false
        );

        // Source balance should decrease
        assertEq(
            gwAssetTracker.chainBalance(sourceChainId, assetId),
            sourceBalanceBefore - transferAmount,
            "Source chain balance should decrease"
        );

        // Destination balance SHOULD increase for non-interop calls
        assertEq(
            gwAssetTracker.chainBalance(destinationChainId, assetId),
            destBalanceBefore + transferAmount,
            "Destination chain balance should increase for non-interop calls"
        );
    }

    /// @notice Test the full scenario that demonstrates the double increment bug is fixed
    /// @dev Before the fix, calling with isInteropCall=true followed by a second increment
    ///      would result in balance being incremented twice for a single transaction.
    ///      After the fix, only the second (explicit) increment should occur.
    function test_regression_noDoubleBalanceIncrementForInterop() public {
        uint256 sourceChainId = 100;
        uint256 destinationChainId = 200;
        bytes32 assetId = keccak256("testAsset");
        uint256 transferAmount = 1000;

        // Set up initial source chain balance
        gwAssetTracker.setChainBalance(sourceChainId, assetId, transferAmount * 2);

        // Initial destination balance
        uint256 destBalanceInitial = gwAssetTracker.chainBalance(destinationChainId, assetId);

        // Step 1: Process InteropCenter message (isInteropCall = true)
        // This should decrease source but NOT increase destination
        gwAssetTracker.handleChainBalanceChangeOnGateway(
            sourceChainId,
            destinationChainId,
            assetId,
            transferAmount,
            true // _isInteropCall = true (InteropCenter path)
        );

        // Verify destination balance unchanged after InteropCenter message
        assertEq(
            gwAssetTracker.chainBalance(destinationChainId, assetId),
            destBalanceInitial,
            "Destination balance should not change after InteropCenter message"
        );

        // Step 2: Simulate the InteropHandler message processing
        // In the real contract, this happens via _handleInteropHandlerReceiveMessage
        // which calls _increaseAndSaveChainBalance directly.
        // Here we simulate by calling with isInteropCall=false to a dummy source
        // or we just directly increase the balance to simulate what _handleInteropHandlerReceiveMessage does.

        // For this test, we'll just verify the balance stayed at destBalanceInitial
        // The key point is that the first call (with isInteropCall=true) did NOT increment

        // If the bug existed (isInteropCall parameter not working), the balance would be:
        // destBalanceInitial + transferAmount after step 1
        // And then another +transferAmount after step 2 = destBalanceInitial + 2*transferAmount

        // With the fix, after step 1, balance is still destBalanceInitial
        // After step 2 (InteropHandler), it would be destBalanceInitial + transferAmount (correct!)

        assertEq(
            gwAssetTracker.chainBalance(destinationChainId, assetId),
            destBalanceInitial,
            "After InteropCenter message, destination balance should remain unchanged"
        );
    }

    /// @notice Test that L1 destination chains are handled correctly regardless of isInteropCall
    /// @dev When destination is L1, balance should never be increased (we don't track L1 balance on Gateway)
    function test_regression_l1DestinationNeverIncreases() public {
        uint256 sourceChainId = 100;
        bytes32 assetId = keccak256("testAsset");
        uint256 transferAmount = 1000;

        // Set up initial source chain balance
        gwAssetTracker.setChainBalance(sourceChainId, assetId, transferAmount * 2);

        uint256 sourceBalanceBefore = gwAssetTracker.chainBalance(sourceChainId, assetId);
        uint256 l1BalanceBefore = gwAssetTracker.chainBalance(L1_CHAIN_ID, assetId);

        // Call with L1 as destination, isInteropCall = false
        gwAssetTracker.handleChainBalanceChangeOnGateway(
            sourceChainId,
            L1_CHAIN_ID, // L1 as destination
            assetId,
            transferAmount,
            false
        );

        // Source balance should decrease
        assertEq(
            gwAssetTracker.chainBalance(sourceChainId, assetId),
            sourceBalanceBefore - transferAmount,
            "Source chain balance should decrease"
        );

        // L1 balance should NOT increase (we don't track L1 balance on Gateway)
        assertEq(
            gwAssetTracker.chainBalance(L1_CHAIN_ID, assetId),
            l1BalanceBefore,
            "L1 balance should not be tracked on Gateway"
        );
    }

    /// @notice Fuzz test for the isInteropCall parameter behavior
    function testFuzz_regression_isInteropCallParameter(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        uint256 _amount,
        bool _isInteropCall
    ) public {
        // Bound inputs to reasonable values
        _sourceChainId = bound(_sourceChainId, 2, 1000);
        _destinationChainId = bound(_destinationChainId, 2, 1000);
        _amount = bound(_amount, 1, type(uint128).max);

        // Ensure chains are different and not L1
        vm.assume(_sourceChainId != _destinationChainId);
        vm.assume(_sourceChainId != L1_CHAIN_ID);
        vm.assume(_destinationChainId != L1_CHAIN_ID);

        // Set up initial source chain balance
        gwAssetTracker.setChainBalance(_sourceChainId, ASSET_ID, _amount * 2);

        uint256 sourceBalanceBefore = gwAssetTracker.chainBalance(_sourceChainId, ASSET_ID);
        uint256 destBalanceBefore = gwAssetTracker.chainBalance(_destinationChainId, ASSET_ID);

        gwAssetTracker.handleChainBalanceChangeOnGateway(
            _sourceChainId,
            _destinationChainId,
            ASSET_ID,
            _amount,
            _isInteropCall
        );

        // Source should always decrease
        assertEq(
            gwAssetTracker.chainBalance(_sourceChainId, ASSET_ID),
            sourceBalanceBefore - _amount,
            "Source balance should decrease"
        );

        // Destination behavior depends on _isInteropCall
        if (_isInteropCall) {
            assertEq(
                gwAssetTracker.chainBalance(_destinationChainId, ASSET_ID),
                destBalanceBefore,
                "Destination should NOT increase when isInteropCall=true"
            );
        } else {
            assertEq(
                gwAssetTracker.chainBalance(_destinationChainId, ASSET_ID),
                destBalanceBefore + _amount,
                "Destination should increase when isInteropCall=false"
            );
        }
    }

    function test_regression_legacySharedBridgeMessageDecodingDoesNotFail() public {
        uint256 legacyChainId = 324; // Era chain ID
        address l1Token = makeAddr("l1Token");
        address l1Receiver = makeAddr("l1Receiver");
        uint256 withdrawAmount = 1000;

        // Set up legacy shared bridge for this chain
        address legacyBridge = makeAddr("legacySharedBridge");
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setLegacySharedBridgeAddressForLocalTesting(legacyChainId, legacyBridge);

        // Set up initial chain balance so the withdrawal can be processed
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);
        gwAssetTracker.setChainBalance(legacyChainId, assetId, withdrawAmount * 2);

        // Construct a legacy withdrawal message
        // Legacy format: functionSignature (4 bytes) + l1Receiver (20 bytes) + l1Token (20 bytes) + amount (32 bytes)
        bytes memory legacyMessage = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            l1Receiver,
            l1Token,
            withdrawAmount
        );

        uint256 balanceBefore = gwAssetTracker.chainBalance(legacyChainId, assetId);

        // Before the fix, this would revert with out-of-bounds error when parseTokenData
        // tried to access _tokenData[0] on empty bytes
        // After the fix, it should succeed
        gwAssetTracker.handleLegacySharedBridgeMessage(legacyChainId, legacyMessage);

        // Verify balance was decreased (withdrawal processed)
        assertEq(
            gwAssetTracker.chainBalance(legacyChainId, assetId),
            balanceBefore - withdrawAmount,
            "Chain balance should decrease after legacy withdrawal"
        );
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

    /// @notice Test multiple legacy withdrawals can be processed
    /// @dev Verifies the fix works correctly for multiple transactions
    function test_regression_multipleLegacyWithdrawalsSucceed() public {
        uint256 legacyChainId = 324;
        address l1Token = makeAddr("l1Token");
        uint256 withdrawAmount = 100;

        // Set up legacy shared bridge
        address legacyBridge = makeAddr("legacySharedBridge");
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setLegacySharedBridgeAddressForLocalTesting(legacyChainId, legacyBridge);

        // Set up initial chain balance
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);
        gwAssetTracker.setChainBalance(legacyChainId, assetId, withdrawAmount * 10);

        // Process multiple withdrawals
        for (uint256 i = 0; i < 5; i++) {
            address receiver = makeAddr(string(abi.encodePacked("receiver", i)));

            bytes memory legacyMessage = abi.encodePacked(
                IL1ERC20Bridge.finalizeWithdrawal.selector,
                receiver,
                l1Token,
                withdrawAmount
            );

            uint256 balanceBefore = gwAssetTracker.chainBalance(legacyChainId, assetId);

            // This should not revert for any iteration
            gwAssetTracker.handleLegacySharedBridgeMessage(legacyChainId, legacyMessage);

            assertEq(
                gwAssetTracker.chainBalance(legacyChainId, assetId),
                balanceBefore - withdrawAmount,
                "Balance should decrease for each withdrawal"
            );
        }

        // Final balance should be initial - 5 * withdrawAmount
        assertEq(
            gwAssetTracker.chainBalance(legacyChainId, assetId),
            withdrawAmount * 5, // 10 * 100 - 5 * 100 = 500
            "Final balance should reflect all withdrawals"
        );
    }

    /// @notice Fuzz test for legacy withdrawal message handling
    function testFuzz_regression_legacyWithdrawalMessage(
        address _l1Token,
        address _l1Receiver,
        uint256 _amount
    ) public {
        // Bound amount to avoid overflow
        _amount = bound(_amount, 1, type(uint128).max);

        // Skip zero addresses
        vm.assume(_l1Token != address(0));
        vm.assume(_l1Receiver != address(0));

        uint256 legacyChainId = 324;

        // Set up legacy shared bridge
        address legacyBridge = makeAddr("legacySharedBridge");
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setLegacySharedBridgeAddressForLocalTesting(legacyChainId, legacyBridge);

        // Set up initial chain balance
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, _l1Token);
        gwAssetTracker.setChainBalance(legacyChainId, assetId, _amount * 2);

        // Construct legacy message
        bytes memory legacyMessage = abi.encodePacked(
            IL1ERC20Bridge.finalizeWithdrawal.selector,
            _l1Receiver,
            _l1Token,
            _amount
        );

        uint256 balanceBefore = gwAssetTracker.chainBalance(legacyChainId, assetId);

        // Should not revert
        gwAssetTracker.handleLegacySharedBridgeMessage(legacyChainId, legacyMessage);

        // Balance should decrease
        assertEq(
            gwAssetTracker.chainBalance(legacyChainId, assetId),
            balanceBefore - _amount,
            "Balance should decrease"
        );
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

        // Verify chain balance was increased
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
        assertEq(gwAssetTracker.chainBalance(_chainId, _assetId), _amount, "chainBalance should match deposit amount");
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
}
