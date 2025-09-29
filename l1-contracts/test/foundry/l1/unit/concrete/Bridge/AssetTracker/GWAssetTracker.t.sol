// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {GWAssetTracker} from "contracts/bridge/asset-tracker/GWAssetTracker.sol";
import {IGWAssetTracker} from "contracts/bridge/asset-tracker/IGWAssetTracker.sol";
import {BalanceChange, TokenBalanceMigrationData} from "contracts/common/Messaging.sol";
import {L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_INTEROP_CENTER_ADDR, L2_COMPRESSOR_ADDR, L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS, L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {IChainAssetHandler} from "contracts/bridgehub/IChainAssetHandler.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {IL2ToL1Messenger} from "contracts/common/l2-helpers/IL2ToL1Messenger.sol";
import {IAssetTrackerDataEncoding} from "contracts/bridge/asset-tracker/IAssetTrackerDataEncoding.sol";
import {TOKEN_BALANCE_MIGRATION_DATA_VERSION, BALANCE_CHANGE_VERSION} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY} from "contracts/bridgehub/IMessageRoot.sol";
import {BUNDLE_IDENTIFIER} from "contracts/common/Messaging.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {MAX_BUILT_IN_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {InvalidAssetId, InvalidBuiltInContractMessage, InvalidCanonicalTxHash, InvalidInteropChainId, NotMigratedChain, OnlyWithdrawalsAllowedForPreV30Chains, InvalidV30UpgradeChainBatchNumber, InvalidFunctionSignature, InvalidL2ShardId, InvalidServiceLog} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {ChainIdNotRegistered, InvalidMessage, ReconstructionMismatch, Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract GWAssetTrackerTest is Test {
    GWAssetTracker public gwAssetTracker;
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
        // Deploy GWAssetTracker
        gwAssetTracker = new GWAssetTracker();

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

        // Check that unprocessed deposits was incremented
        assertEq(gwAssetTracker.unprocessedDeposits(CHAIN_ID), 1);

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
        TokenBalanceMigrationData memory data = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: CHAIN_ID,
            assetId: ASSET_ID,
            tokenOriginChainId: ORIGIN_CHAIN_ID,
            amount: AMOUNT,
            migrationNumber: MIGRATION_NUMBER,
            originToken: ORIGIN_TOKEN,
            isL1ToGateway: false
        });

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        gwAssetTracker.confirmMigrationOnGateway(data);
    }

    function test_ParseInteropCall() public {
        bytes memory callData = abi.encodePacked(
            IAssetRouterBase.finalizeDeposit.selector,
            abi.encode(CHAIN_ID, ASSET_ID, abi.encode("transferData"))
        );

        (uint256 fromChainId, bytes32 assetId, bytes memory transferData) = gwAssetTracker.parseInteropCall(callData);

        assertEq(fromChainId, CHAIN_ID);
        assertEq(assetId, ASSET_ID);
        assertEq(transferData, abi.encode("transferData"));
    }
}
