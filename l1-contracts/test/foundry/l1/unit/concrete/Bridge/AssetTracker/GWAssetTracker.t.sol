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

import {L2MessageRoot} from "contracts/core/message-root/L2MessageRoot.sol";

contract GWAssetTrackerTestHelper is GWAssetTracker {
    function getEmptyMessageRoot(uint256 _chainId) external returns (bytes32) {
        return _getEmptyMessageRoot(_chainId);
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

    function testFuzz_HandleChainBalanceIncreaseOnGateway(
        uint256 _amount,
        uint256 _baseTokenAmount
    ) public {
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
}
