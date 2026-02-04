// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

import {InteropCenter, IInteropCenter} from "contracts/interop/InteropCenter.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {ZKTokenNotAvailable, FeeWithdrawalFailed} from "contracts/interop/InteropErrors.sol";
import {L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_BRIDGEHUB_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

/// @title L2InteropFeesTestAbstract
/// @notice Tests for InteropCenter fee configuration and fee collection functionality
/// @dev Tests both fee configuration and actual fee collection during sendBundle operations.
abstract contract L2InteropFeesTestAbstract is L2InteropTestUtils {
    using stdStorage for StdStorage;

    event InteropFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);
    event ProtocolFeesCollected(address indexed recipient, uint256 amount);
    event FixedZKFeesCollected(address indexed payer, address indexed recipient, uint256 amount);
    event ProtocolFeesAccumulated(address indexed coinbase, uint256 amount);
    event FixedZKFeesAccumulated(address indexed payer, address indexed coinbase, uint256 amount);
    event ProtocolFeesClaimed(address indexed coinbase, address indexed receiver, uint256 amount);
    event ZKFeesClaimed(address indexed coinbase, address indexed receiver, uint256 amount);

    TestnetERC20Token internal zkToken;

    function setUp() public virtual override {
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                        setInteropFee Tests
    //////////////////////////////////////////////////////////////*/

    function test_setInteropFee_Success() public {
        uint256 newFee = 0.01 ether;

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(newFee);

        assertEq(l2InteropCenter.interopProtocolFee(), newFee);
    }

    function test_setInteropFee_Unauthorized() public {
        address nonAuthorized = makeAddr("nonAuthorized");
        uint256 newFee = 0.01 ether;

        vm.prank(nonAuthorized);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAuthorized));
        l2InteropCenter.setInteropFee(newFee);
    }

    function test_setInteropFee_EmitsEvent() public {
        uint256 oldFee = l2InteropCenter.interopProtocolFee();
        uint256 newFee = 0.02 ether;

        vm.expectEmit(true, true, false, false);
        emit InteropFeeUpdated(oldFee, newFee);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(newFee);
    }

    function test_setInteropFee_ZeroFee() public {
        // First set a non-zero fee
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(0.01 ether);

        // Then set to zero
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(0);

        assertEq(l2InteropCenter.interopProtocolFee(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        ZK_INTEROP_FEE Constant Tests
    //////////////////////////////////////////////////////////////*/

    function test_ZK_INTEROP_FEE_Value() public view {
        // ZK_INTEROP_FEE should be 1e18 (1 ZK token)
        assertEq(l2InteropCenter.ZK_INTEROP_FEE(), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                    supportsAttribute Tests for useFixedFee
    //////////////////////////////////////////////////////////////*/

    function test_supportsAttribute_UseFixedFee() public view {
        bool supported = l2InteropCenter.supportsAttribute(IERC7786Attributes.useFixedFee.selector);
        assertTrue(supported);
    }

    /*//////////////////////////////////////////////////////////////
                    interopProtocolFee Storage Tests
    //////////////////////////////////////////////////////////////*/

    function test_interopProtocolFee_InitiallyZero() public view {
        // Protocol fee should start at zero
        assertEq(l2InteropCenter.interopProtocolFee(), 0);
    }

    function test_interopProtocolFee_UpdatedBySetInteropFee() public {
        uint256 newFee = 0.05 ether;

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(newFee);

        assertEq(l2InteropCenter.interopProtocolFee(), newFee);
    }

    /*//////////////////////////////////////////////////////////////
                    sendBundle Fee Collection Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice Helper to set up gateway mode for sendBundle tests
    function _setupGatewayMode() internal {
        // Mock currentSettlementLayerChainId to return current chain (not L1_CHAIN_ID)
        // This enables gateway mode for sendBundle
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(block.chainid)
        );
    }

    /// @notice Helper to build a simple interop call for fee testing
    function _buildSimpleCall() internal view returns (InteropCallStarter[] memory calls) {
        calls = new InteropCallStarter[](1);
        bytes[] memory callAttributes = new bytes[](0);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(interopTargetContract),
            data: hex"",
            callAttributes: callAttributes
        });
    }

    /// @notice Test that base token protocol fees are collected when useFixedFee=false
    function test_sendBundle_collectsBaseTokenFees() public {
        _setupGatewayMode();

        // Set a protocol fee
        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        // Prepare sender with enough ETH
        address sender = makeAddr("feeSender");
        vm.deal(sender, 10 ether);

        // Set up the coinbase to receive fees
        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);
        uint256 coinbaseBalanceBefore = coinbaseAddr.balance;

        // Build bundle attributes with useFixedFee=false
        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(
            address(0),
            UNBUNDLER_ADDRESS,
            false // useFixedFee = false means base token fees
        );

        InteropCallStarter[] memory calls = _buildSimpleCall();

        // Send bundle with protocol fee included in msg.value
        // For 1 call, fee = protocolFee * 1
        vm.prank(sender);
        l2InteropCenter.sendBundle{value: protocolFee}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify coinbase received the fee
        assertEq(coinbaseAddr.balance, coinbaseBalanceBefore + protocolFee, "Coinbase should receive protocol fee");
    }

    /// @notice Test that base token fees scale with call count
    function test_sendBundle_baseTokenFeesScaleWithCallCount() public {
        _setupGatewayMode();

        // Set a protocol fee
        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        // Prepare sender
        address sender = makeAddr("feeSender");
        vm.deal(sender, 10 ether);

        // Set up coinbase
        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);
        uint256 coinbaseBalanceBefore = coinbaseAddr.balance;

        // Build 3 calls
        InteropCallStarter[] memory calls = new InteropCallStarter[](3);
        bytes[] memory callAttributes = new bytes[](0);
        for (uint256 i = 0; i < 3; i++) {
            calls[i] = InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(interopTargetContract),
                data: hex"",
                callAttributes: callAttributes
            });
        }

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, false);

        // Total fee should be protocolFee * 3
        uint256 totalFee = protocolFee * 3;

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: totalFee}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        assertEq(coinbaseAddr.balance, coinbaseBalanceBefore + totalFee, "Coinbase should receive fee for all calls");
    }

    /// @notice Test that no base token fees are charged when interopProtocolFee is zero
    function test_sendBundle_noFeesWhenProtocolFeeZero() public {
        _setupGatewayMode();

        // Ensure protocol fee is zero
        assertEq(l2InteropCenter.interopProtocolFee(), 0, "Protocol fee should start at zero");

        address sender = makeAddr("feeSender");
        vm.deal(sender, 10 ether);

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);
        uint256 coinbaseBalanceBefore = coinbaseAddr.balance;

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, false);

        InteropCallStarter[] memory calls = _buildSimpleCall();

        // Should work with zero value when fee is zero
        vm.prank(sender);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        assertEq(coinbaseAddr.balance, coinbaseBalanceBefore, "Coinbase balance should not change when fee is zero");
    }

    /// @notice Test that ProtocolFeesCollected event is emitted
    function test_sendBundle_emitsProtocolFeesCollectedEvent() public {
        _setupGatewayMode();

        uint256 protocolFee = 0.02 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        address sender = makeAddr("feeSender");
        vm.deal(sender, 10 ether);

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, false);

        InteropCallStarter[] memory calls = _buildSimpleCall();

        vm.expectEmit(true, false, false, true);
        emit ProtocolFeesCollected(coinbaseAddr, protocolFee);

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: protocolFee}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );
    }

    /// @notice Test ZK token fee collection when useFixedFee=true
    function test_sendBundle_collectsZKTokenFees() public {
        _setupGatewayMode();

        // Deploy ZK token
        zkToken = new TestnetERC20Token("ZK Token", "ZK", 18);

        // Set up ZK token in InteropCenter via storage
        bytes32 zkTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, address(zkToken));

        // Mock NTV to return the zkToken address for the asset ID
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, zkTokenAssetId),
            abi.encode(address(zkToken))
        );

        // Set ZK_TOKEN_ASSET_ID in InteropCenter storage (slot varies, use stdStorage)
        stdstore.target(L2_INTEROP_CENTER_ADDR).sig("ZK_TOKEN_ASSET_ID()").checked_write(zkTokenAssetId);

        // Prepare sender with ZK tokens
        address sender = makeAddr("zkFeeSender");
        uint256 zkFeePerCall = l2InteropCenter.ZK_INTEROP_FEE(); // 1e18
        zkToken.mint(sender, zkFeePerCall * 10);

        // Approve InteropCenter to spend ZK tokens
        vm.prank(sender);
        zkToken.approve(L2_INTEROP_CENTER_ADDR, type(uint256).max);

        // Set up coinbase
        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);
        uint256 coinbaseZKBefore = zkToken.balanceOf(coinbaseAddr);

        // Build bundle with useFixedFee=true
        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(
            address(0),
            UNBUNDLER_ADDRESS,
            true // useFixedFee = true means ZK token fees
        );

        InteropCallStarter[] memory calls = _buildSimpleCall();

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify coinbase received ZK tokens
        assertEq(
            zkToken.balanceOf(coinbaseAddr),
            coinbaseZKBefore + zkFeePerCall,
            "Coinbase should receive ZK token fee"
        );
    }

    /// @notice Test that ZK token fees scale with call count
    function test_sendBundle_zkTokenFeesScaleWithCallCount() public {
        _setupGatewayMode();

        // Deploy and set up ZK token
        zkToken = new TestnetERC20Token("ZK Token", "ZK", 18);
        bytes32 zkTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, address(zkToken));

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, zkTokenAssetId),
            abi.encode(address(zkToken))
        );

        stdstore.target(L2_INTEROP_CENTER_ADDR).sig("ZK_TOKEN_ASSET_ID()").checked_write(zkTokenAssetId);

        address sender = makeAddr("zkFeeSender");
        uint256 zkFeePerCall = l2InteropCenter.ZK_INTEROP_FEE();
        uint256 callCount = 3;
        zkToken.mint(sender, zkFeePerCall * callCount * 2);

        vm.prank(sender);
        zkToken.approve(L2_INTEROP_CENTER_ADDR, type(uint256).max);

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);
        uint256 coinbaseZKBefore = zkToken.balanceOf(coinbaseAddr);

        // Build 3 calls
        InteropCallStarter[] memory calls = new InteropCallStarter[](callCount);
        bytes[] memory callAttributes = new bytes[](0);
        for (uint256 i = 0; i < callCount; i++) {
            calls[i] = InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(interopTargetContract),
                data: hex"",
                callAttributes: callAttributes
            });
        }

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, true);

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        uint256 expectedFee = zkFeePerCall * callCount;
        assertEq(
            zkToken.balanceOf(coinbaseAddr),
            coinbaseZKBefore + expectedFee,
            "Coinbase should receive ZK fee for all calls"
        );
    }

    /// @notice Test that FixedZKFeesCollected event is emitted
    function test_sendBundle_emitsFixedZKFeesCollectedEvent() public {
        _setupGatewayMode();

        // Set up ZK token
        zkToken = new TestnetERC20Token("ZK Token", "ZK", 18);
        bytes32 zkTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, address(zkToken));

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, zkTokenAssetId),
            abi.encode(address(zkToken))
        );

        stdstore.target(L2_INTEROP_CENTER_ADDR).sig("ZK_TOKEN_ASSET_ID()").checked_write(zkTokenAssetId);

        address sender = makeAddr("zkFeeSender");
        uint256 zkFeePerCall = l2InteropCenter.ZK_INTEROP_FEE();
        zkToken.mint(sender, zkFeePerCall * 10);

        vm.prank(sender);
        zkToken.approve(L2_INTEROP_CENTER_ADDR, type(uint256).max);

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, true);

        InteropCallStarter[] memory calls = _buildSimpleCall();

        vm.expectEmit(true, true, false, true);
        emit FixedZKFeesCollected(sender, coinbaseAddr, zkFeePerCall);

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );
    }

    /// @notice Test that useFixedFee=true skips base token protocol fee
    function test_sendBundle_fixedFeeSkipsBaseTokenFee() public {
        _setupGatewayMode();

        // Set a non-zero protocol fee
        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        // Set up ZK token
        zkToken = new TestnetERC20Token("ZK Token", "ZK", 18);
        bytes32 zkTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, address(zkToken));

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, zkTokenAssetId),
            abi.encode(address(zkToken))
        );

        stdstore.target(L2_INTEROP_CENTER_ADDR).sig("ZK_TOKEN_ASSET_ID()").checked_write(zkTokenAssetId);

        address sender = makeAddr("zkFeeSender");
        uint256 zkFeePerCall = l2InteropCenter.ZK_INTEROP_FEE();
        zkToken.mint(sender, zkFeePerCall * 10);
        vm.deal(sender, 10 ether);

        vm.prank(sender);
        zkToken.approve(L2_INTEROP_CENTER_ADDR, type(uint256).max);

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);
        uint256 coinbaseETHBefore = coinbaseAddr.balance;

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(
            address(0),
            UNBUNDLER_ADDRESS,
            true // useFixedFee = true
        );

        InteropCallStarter[] memory calls = _buildSimpleCall();

        // Should work with 0 ETH value because useFixedFee skips base token fee
        vm.prank(sender);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Coinbase ETH balance should NOT have increased (ZK fees were collected instead)
        assertEq(coinbaseAddr.balance, coinbaseETHBefore, "Coinbase ETH should not increase with useFixedFee=true");
    }

    /// @notice Test that ZKTokenNotAvailable is thrown when ZK token is not set up
    function test_sendBundle_revertsWhenZKTokenNotAvailable() public {
        _setupGatewayMode();

        // Don't set up ZK token - leave ZK_TOKEN_ASSET_ID as zero or mock to return address(0)
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector),
            abi.encode(address(0))
        );

        address sender = makeAddr("sender");
        vm.deal(sender, 10 ether);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(
            address(0),
            UNBUNDLER_ADDRESS,
            true // useFixedFee = true requires ZK token
        );

        InteropCallStarter[] memory calls = _buildSimpleCall();

        vm.prank(sender);
        vm.expectRevert(ZKTokenNotAvailable.selector);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );
    }

    /// @notice Test that protocol fees accumulate when coinbase is a reverting contract
    function test_sendBundle_accumulatesProtocolFeesWhenCoinbaseReverts() public {
        _setupGatewayMode();

        // Set a protocol fee
        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        // Create a reverting contract as coinbase
        RevertingReceiver revertingCoinbase = new RevertingReceiver();
        vm.coinbase(address(revertingCoinbase));

        // Prepare sender
        address sender = makeAddr("feeSender");
        vm.deal(sender, 10 ether);

        // Check initial accumulated fees
        assertEq(l2InteropCenter.accumulatedProtocolFees(address(revertingCoinbase)), 0);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, false);
        InteropCallStarter[] memory calls = _buildSimpleCall();

        // Expect accumulation event instead of collection event
        vm.expectEmit(true, false, false, true);
        emit ProtocolFeesAccumulated(address(revertingCoinbase), protocolFee);

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: protocolFee}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify fees were accumulated
        assertEq(
            l2InteropCenter.accumulatedProtocolFees(address(revertingCoinbase)),
            protocolFee,
            "Protocol fees should be accumulated"
        );
    }

    /// @notice Test claiming accumulated protocol fees
    function test_claimProtocolFees_Success() public {
        _setupGatewayMode();

        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        // Create a reverting contract as coinbase
        RevertingReceiver revertingCoinbase = new RevertingReceiver();
        vm.coinbase(address(revertingCoinbase));

        // Send bundle to accumulate fees
        address sender = makeAddr("feeSender");
        vm.deal(sender, 10 ether);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, false);
        InteropCallStarter[] memory calls = _buildSimpleCall();

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: protocolFee}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Now claim fees to a different receiver
        address receiver = makeAddr("receiver");
        uint256 receiverBalanceBefore = receiver.balance;

        vm.expectEmit(true, true, false, true);
        emit ProtocolFeesClaimed(address(revertingCoinbase), receiver, protocolFee);

        vm.prank(address(revertingCoinbase));
        l2InteropCenter.claimProtocolFees(receiver);

        // Verify receiver got the fees
        assertEq(receiver.balance, receiverBalanceBefore + protocolFee, "Receiver should get claimed fees");

        // Verify accumulated fees are now zero
        assertEq(
            l2InteropCenter.accumulatedProtocolFees(address(revertingCoinbase)),
            0,
            "Accumulated fees should be zero after claim"
        );
    }

    /// @notice Test that claimProtocolFees returns early when no fees to claim
    function test_claimProtocolFees_NoFeesToClaim() public {
        address claimer = makeAddr("claimer");
        address receiver = makeAddr("receiver");

        // Should not revert, just return early
        vm.prank(claimer);
        l2InteropCenter.claimProtocolFees(receiver);

        // No state changes expected
        assertEq(l2InteropCenter.accumulatedProtocolFees(claimer), 0);
    }

    /// @notice Test that ZK fees accumulate when coinbase transfer fails
    function test_sendBundle_accumulatesZKFeesWhenCoinbaseReverts() public {
        _setupGatewayMode();

        // Deploy ZK token that fails transfers to a specific address
        FailingTransferToken failingToken = new FailingTransferToken("ZK Token", "ZK", 18);
        bytes32 zkTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, address(failingToken));

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, zkTokenAssetId),
            abi.encode(address(failingToken))
        );

        stdstore.target(L2_INTEROP_CENTER_ADDR).sig("ZK_TOKEN_ASSET_ID()").checked_write(zkTokenAssetId);

        // Set coinbase to the address that fails transfers
        address blockedCoinbase = failingToken.BLOCKED_ADDRESS();
        vm.coinbase(blockedCoinbase);

        // Prepare sender
        address sender = makeAddr("zkFeeSender");
        uint256 zkFeePerCall = l2InteropCenter.ZK_INTEROP_FEE();
        failingToken.mint(sender, zkFeePerCall * 10);

        vm.prank(sender);
        failingToken.approve(L2_INTEROP_CENTER_ADDR, type(uint256).max);

        // Check initial accumulated fees
        assertEq(l2InteropCenter.accumulatedZKFees(blockedCoinbase), 0);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, true);
        InteropCallStarter[] memory calls = _buildSimpleCall();

        // Expect accumulation event
        vm.expectEmit(true, true, false, true);
        emit FixedZKFeesAccumulated(sender, blockedCoinbase, zkFeePerCall);

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify fees were accumulated
        assertEq(l2InteropCenter.accumulatedZKFees(blockedCoinbase), zkFeePerCall, "ZK fees should be accumulated");

        // Verify InteropCenter holds the tokens
        assertEq(
            failingToken.balanceOf(L2_INTEROP_CENTER_ADDR),
            zkFeePerCall,
            "InteropCenter should hold accumulated ZK tokens"
        );
    }

    /// @notice Test claiming accumulated ZK fees
    function test_claimZKFees_Success() public {
        _setupGatewayMode();

        // Deploy ZK token that fails transfers to a specific address
        FailingTransferToken failingToken = new FailingTransferToken("ZK Token", "ZK", 18);
        bytes32 zkTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, address(failingToken));

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, zkTokenAssetId),
            abi.encode(address(failingToken))
        );

        stdstore.target(L2_INTEROP_CENTER_ADDR).sig("ZK_TOKEN_ASSET_ID()").checked_write(zkTokenAssetId);

        // Set coinbase to the address that fails transfers
        address blockedCoinbase = failingToken.BLOCKED_ADDRESS();
        vm.coinbase(blockedCoinbase);

        // Send bundle to accumulate fees
        address sender = makeAddr("zkFeeSender");
        uint256 zkFeePerCall = l2InteropCenter.ZK_INTEROP_FEE();
        failingToken.mint(sender, zkFeePerCall * 10);

        vm.prank(sender);
        failingToken.approve(L2_INTEROP_CENTER_ADDR, type(uint256).max);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, true);
        InteropCallStarter[] memory calls = _buildSimpleCall();

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify fees were accumulated
        assertEq(l2InteropCenter.accumulatedZKFees(blockedCoinbase), zkFeePerCall, "Fees should be accumulated");

        // Now claim fees to a different receiver (not blocked)
        address receiver = makeAddr("receiver");
        uint256 receiverZKBefore = failingToken.balanceOf(receiver);

        vm.expectEmit(true, true, false, true);
        emit ZKFeesClaimed(blockedCoinbase, receiver, zkFeePerCall);

        vm.prank(blockedCoinbase);
        l2InteropCenter.claimZKFees(receiver);

        // Verify receiver got the ZK tokens
        assertEq(
            failingToken.balanceOf(receiver),
            receiverZKBefore + zkFeePerCall,
            "Receiver should get claimed ZK fees"
        );

        // Verify accumulated fees are now zero
        assertEq(
            l2InteropCenter.accumulatedZKFees(blockedCoinbase),
            0,
            "Accumulated ZK fees should be zero after claim"
        );
    }

    /// @notice Test that claimZKFees returns early when no fees to claim
    function test_claimZKFees_NoFeesToClaim() public {
        // Set up ZK token for the claim function to work
        zkToken = new TestnetERC20Token("ZK Token", "ZK", 18);
        bytes32 zkTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, address(zkToken));

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, zkTokenAssetId),
            abi.encode(address(zkToken))
        );

        stdstore.target(L2_INTEROP_CENTER_ADDR).sig("ZK_TOKEN_ASSET_ID()").checked_write(zkTokenAssetId);

        address claimer = makeAddr("claimer");
        address receiver = makeAddr("receiver");

        // Should not revert, just return early
        vm.prank(claimer);
        l2InteropCenter.claimZKFees(receiver);

        // No state changes expected
        assertEq(l2InteropCenter.accumulatedZKFees(claimer), 0);
    }

    /// @notice Test multiple fee accumulations before claiming
    function test_claimProtocolFees_MultipleAccumulations() public {
        _setupGatewayMode();

        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        RevertingReceiver revertingCoinbase = new RevertingReceiver();
        vm.coinbase(address(revertingCoinbase));

        address sender = makeAddr("feeSender");
        vm.deal(sender, 10 ether);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, false);
        InteropCallStarter[] memory calls = _buildSimpleCall();

        // Send multiple bundles to accumulate fees
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(sender);
            l2InteropCenter.sendBundle{value: protocolFee}(
                InteroperableAddress.formatEvmV1(destinationChainId),
                calls,
                bundleAttributes
            );
        }

        // Verify total accumulated
        uint256 totalAccumulated = protocolFee * 3;
        assertEq(l2InteropCenter.accumulatedProtocolFees(address(revertingCoinbase)), totalAccumulated);

        // Claim all at once
        address receiver = makeAddr("receiver");
        vm.prank(address(revertingCoinbase));
        l2InteropCenter.claimProtocolFees(receiver);

        assertEq(receiver.balance, totalAccumulated, "Receiver should get all accumulated fees");
        assertEq(l2InteropCenter.accumulatedProtocolFees(address(revertingCoinbase)), 0);
    }
}

/// @notice Helper contract that reverts on any ETH or token transfer
contract RevertingReceiver {
    receive() external payable {
        revert("RevertingReceiver: no ETH accepted");
    }

    fallback() external payable {
        revert("RevertingReceiver: no calls accepted");
    }
}

/// @notice ERC20 token that reverts transfers to a specific blocked address
/// @dev Used to test ZK fee accumulation when transfer to coinbase fails
contract FailingTransferToken is TestnetERC20Token {
    address public constant BLOCKED_ADDRESS = address(0xB10C3ED);

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) TestnetERC20Token(name_, symbol_, decimals_) {}

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (to == BLOCKED_ADDRESS) {
            revert("FailingTransferToken: transfer to blocked address");
        }
        return super.transfer(to, amount);
    }
}
