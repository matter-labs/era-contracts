// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

import {IInteropCenter, InteropCenter} from "contracts/interop/InteropCenter.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {FeeWithdrawalFailed, ZKTokenNotAvailable} from "contracts/interop/InteropErrors.sol";
import {
    L2_INTEROP_CENTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_BOOTLOADER_ADDRESS
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT,
    L2_BASE_TOKEN_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

/// @title L2InteropFeesTestAbstract
/// @notice Tests for InteropCenter fee configuration and fee collection functionality
/// @dev Tests both fee configuration and actual fee collection during sendBundle operations.
abstract contract L2InteropFeesTestAbstract is L2InteropTestUtils {
    using stdStorage for StdStorage;

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
        emit IInteropCenter.InteropFeeUpdated(oldFee, newFee);

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
        // ZK_INTEROP_FEE should be 10e18 (10 ZK tokens)
        assertEq(l2InteropCenter.ZK_INTEROP_FEE(), 10e18);
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

    /// @notice Test that base token protocol fees are accumulated when useFixedFee=false
    function test_sendBundle_collectsBaseTokenFees() public {
        _setupGatewayMode();

        // Set a protocol fee
        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        // Prepare sender with enough ETH
        address sender = makeAddr("feeSender");
        vm.deal(sender, 10 ether);

        // Set up the coinbase
        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

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

        // Verify fees were accumulated for coinbase
        assertEq(
            l2InteropCenter.accumulatedProtocolFees(coinbaseAddr),
            protocolFee,
            "Protocol fees should be accumulated for coinbase"
        );
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

        assertEq(
            l2InteropCenter.accumulatedProtocolFees(coinbaseAddr),
            totalFee,
            "Protocol fees should be accumulated for all calls"
        );
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

    /// @notice Test that ProtocolFeesAccumulated event is emitted
    function test_sendBundle_emitsProtocolFeesAccumulatedEvent() public {
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
        emit IInteropCenter.ProtocolFeesAccumulated(coinbaseAddr, protocolFee);

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

        // Verify fees accumulated for coinbase
        assertEq(
            l2InteropCenter.accumulatedZKFees(coinbaseAddr),
            zkFeePerCall,
            "Coinbase should have accumulated ZK token fee"
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
            l2InteropCenter.accumulatedZKFees(coinbaseAddr),
            expectedFee,
            "Coinbase should have accumulated ZK fee for all calls"
        );
    }

    /// @notice Test that FixedZKFeesAccumulated event is emitted
    function test_sendBundle_emitsFixedZKFeesAccumulatedEvent() public {
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
        emit IInteropCenter.FixedZKFeesAccumulated(sender, coinbaseAddr, zkFeePerCall);

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
        emit IInteropCenter.ProtocolFeesAccumulated(address(revertingCoinbase), protocolFee);

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
        emit IInteropCenter.ProtocolFeesClaimed(address(revertingCoinbase), receiver, protocolFee);

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

    /// @notice Test that ZK fees are always accumulated for coinbase
    function test_sendBundle_accumulatesZKFees() public {
        _setupGatewayMode();

        // Deploy ZK token
        zkToken = new TestnetERC20Token("ZK Token", "ZK", 18);
        bytes32 zkTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, address(zkToken));

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, zkTokenAssetId),
            abi.encode(address(zkToken))
        );

        stdstore.target(L2_INTEROP_CENTER_ADDR).sig("ZK_TOKEN_ASSET_ID()").checked_write(zkTokenAssetId);

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

        // Prepare sender
        address sender = makeAddr("zkFeeSender");
        uint256 zkFeePerCall = l2InteropCenter.ZK_INTEROP_FEE();
        zkToken.mint(sender, zkFeePerCall * 10);

        vm.prank(sender);
        zkToken.approve(L2_INTEROP_CENTER_ADDR, type(uint256).max);

        // Check initial accumulated fees
        assertEq(l2InteropCenter.accumulatedZKFees(coinbaseAddr), 0);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, true);
        InteropCallStarter[] memory calls = _buildSimpleCall();

        // Expect accumulation event
        vm.expectEmit(true, true, false, true);
        emit IInteropCenter.FixedZKFeesAccumulated(sender, coinbaseAddr, zkFeePerCall);

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify fees were accumulated
        assertEq(l2InteropCenter.accumulatedZKFees(coinbaseAddr), zkFeePerCall, "ZK fees should be accumulated");

        // Verify InteropCenter holds the tokens
        assertEq(
            zkToken.balanceOf(L2_INTEROP_CENTER_ADDR),
            zkFeePerCall,
            "InteropCenter should hold accumulated ZK tokens"
        );
    }

    /// @notice Test claiming accumulated ZK fees
    function test_claimZKFees_Success() public {
        _setupGatewayMode();

        // Deploy ZK token
        zkToken = new TestnetERC20Token("ZK Token", "ZK", 18);
        bytes32 zkTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, address(zkToken));

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, zkTokenAssetId),
            abi.encode(address(zkToken))
        );

        stdstore.target(L2_INTEROP_CENTER_ADDR).sig("ZK_TOKEN_ASSET_ID()").checked_write(zkTokenAssetId);

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

        // Send bundle to accumulate fees
        address sender = makeAddr("zkFeeSender");
        uint256 zkFeePerCall = l2InteropCenter.ZK_INTEROP_FEE();
        zkToken.mint(sender, zkFeePerCall * 10);

        vm.prank(sender);
        zkToken.approve(L2_INTEROP_CENTER_ADDR, type(uint256).max);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, true);
        InteropCallStarter[] memory calls = _buildSimpleCall();

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify fees were accumulated
        assertEq(l2InteropCenter.accumulatedZKFees(coinbaseAddr), zkFeePerCall, "Fees should be accumulated");

        // Claim fees to a receiver
        address receiver = makeAddr("receiver");
        uint256 receiverZKBefore = zkToken.balanceOf(receiver);

        vm.expectEmit(true, true, false, true);
        emit IInteropCenter.ZKFeesClaimed(coinbaseAddr, receiver, zkFeePerCall);

        vm.prank(coinbaseAddr);
        l2InteropCenter.claimZKFees(receiver);

        // Verify receiver got the ZK tokens
        assertEq(zkToken.balanceOf(receiver), receiverZKBefore + zkFeePerCall, "Receiver should get claimed ZK fees");

        // Verify accumulated fees are now zero
        assertEq(l2InteropCenter.accumulatedZKFees(coinbaseAddr), 0, "Accumulated ZK fees should be zero after claim");
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

    /*//////////////////////////////////////////////////////////////
                    useFixedFee Default Behavior Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that sendBundle succeeds when useFixedFee attribute is missing (defaults to false = base token fees)
    function test_sendBundle_succeedsWhenUseFixedFeeMissing() public {
        _setupGatewayMode();

        // Set a protocol fee to verify base token fee path is taken
        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        address sender = makeAddr("sender");
        vm.deal(sender, 10 ether);

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

        // Build bundle attributes WITHOUT useFixedFee (only unbundler)
        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        InteropCallStarter[] memory calls = _buildSimpleCall();

        // Should succeed with base token fee (useFixedFee defaults to false)
        vm.prank(sender);
        l2InteropCenter.sendBundle{value: protocolFee}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify base token fees were collected (not ZK fees)
        assertEq(
            l2InteropCenter.accumulatedProtocolFees(coinbaseAddr),
            protocolFee,
            "Protocol fees should be accumulated when useFixedFee defaults to false"
        );
        assertEq(
            l2InteropCenter.accumulatedZKFees(coinbaseAddr),
            0,
            "ZK fees should be zero when useFixedFee defaults to false"
        );
    }

    /// @notice Test that sendMessage succeeds when useFixedFee attribute is missing (defaults to false = base token fees)
    function test_sendMessage_succeedsWhenUseFixedFeeMissing() public {
        _setupGatewayMode();

        address sender = makeAddr("sender");
        vm.deal(sender, 10 ether);

        bytes memory recipient = InteroperableAddress.formatEvmV1(destinationChainId, interopTargetContract);
        bytes memory payload = hex"";

        // Build attributes WITHOUT useFixedFee (empty attributes)
        bytes[] memory attributes = new bytes[](0);

        // Should succeed (useFixedFee defaults to false)
        vm.prank(sender);
        l2InteropCenter.sendMessage{value: 0}(recipient, payload, attributes);
    }

    /*//////////////////////////////////////////////////////////////
                    Claim Failure-Path Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that claimProtocolFees reverts with FeeWithdrawalFailed when receiver reverts
    function test_claimProtocolFees_revertsWhenReceiverReverts() public {
        _setupGatewayMode();

        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        // Use a normal address as coinbase
        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

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

        // Try to claim fees to a reverting receiver
        RevertingReceiver revertingReceiver = new RevertingReceiver();

        vm.prank(coinbaseAddr);
        vm.expectRevert(FeeWithdrawalFailed.selector);
        l2InteropCenter.claimProtocolFees(address(revertingReceiver));
    }

    /// @notice Test claimProtocolFees with zero-address receiver
    function test_claimProtocolFees_zeroAddressReceiver() public {
        _setupGatewayMode();

        uint256 protocolFee = 0.01 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

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

        // Claim to address(0) - the low-level call to address(0) succeeds (ETH burned)
        vm.prank(coinbaseAddr);
        l2InteropCenter.claimProtocolFees(address(0));

        // Accumulated fees should be cleared
        assertEq(l2InteropCenter.accumulatedProtocolFees(coinbaseAddr), 0, "Accumulated fees should be cleared");
    }

    /// @notice Test claimZKFees with zero-address receiver
    function test_claimZKFees_zeroAddressReceiver() public {
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

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

        address sender = makeAddr("zkFeeSender");
        uint256 zkFeePerCall = l2InteropCenter.ZK_INTEROP_FEE();
        zkToken.mint(sender, zkFeePerCall * 10);

        vm.prank(sender);
        zkToken.approve(L2_INTEROP_CENTER_ADDR, type(uint256).max);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, true);
        InteropCallStarter[] memory calls = _buildSimpleCall();

        vm.prank(sender);
        l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // SafeERC20 safeTransfer to address(0) will revert
        vm.prank(coinbaseAddr);
        vm.expectRevert("ERC20: transfer to the zero address");
        l2InteropCenter.claimZKFees(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                    Exact Fee Accounting Tests
    //////////////////////////////////////////////////////////////*/

    /// @notice Test exact fee accounting with multiple bundles to the same coinbase
    function test_sendBundle_multipleBundlesAccumulateFees() public {
        _setupGatewayMode();

        uint256 protocolFee = 0.005 ether;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2InteropCenter.setInteropFee(protocolFee);

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

        address sender = makeAddr("feeSender");
        vm.deal(sender, 100 ether);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, false);

        uint256 totalExpectedFees;

        // Bundle 1: 1 call
        {
            InteropCallStarter[] memory calls1 = _buildSimpleCall();
            uint256 fee1 = protocolFee * 1;
            totalExpectedFees += fee1;

            vm.prank(sender);
            l2InteropCenter.sendBundle{value: fee1}(
                InteroperableAddress.formatEvmV1(destinationChainId),
                calls1,
                bundleAttributes
            );
        }

        // Bundle 2: 3 calls
        {
            InteropCallStarter[] memory calls2 = new InteropCallStarter[](3);
            bytes[] memory callAttributes = new bytes[](0);
            for (uint256 i = 0; i < 3; i++) {
                calls2[i] = InteropCallStarter({
                    to: InteroperableAddress.formatEvmV1(interopTargetContract),
                    data: hex"",
                    callAttributes: callAttributes
                });
            }
            uint256 fee2 = protocolFee * 3;
            totalExpectedFees += fee2;

            vm.prank(sender);
            l2InteropCenter.sendBundle{value: fee2}(
                InteroperableAddress.formatEvmV1(destinationChainId),
                calls2,
                bundleAttributes
            );
        }

        // Bundle 3: 2 calls
        {
            InteropCallStarter[] memory calls3 = new InteropCallStarter[](2);
            bytes[] memory callAttributes = new bytes[](0);
            for (uint256 i = 0; i < 2; i++) {
                calls3[i] = InteropCallStarter({
                    to: InteroperableAddress.formatEvmV1(interopTargetContract),
                    data: hex"",
                    callAttributes: callAttributes
                });
            }
            uint256 fee3 = protocolFee * 2;
            totalExpectedFees += fee3;

            vm.prank(sender);
            l2InteropCenter.sendBundle{value: fee3}(
                InteroperableAddress.formatEvmV1(destinationChainId),
                calls3,
                bundleAttributes
            );
        }

        // Total: 1 + 3 + 2 = 6 calls * 0.005 ether = 0.03 ether
        assertEq(totalExpectedFees, protocolFee * 6, "Expected fee total should be 6 * protocolFee");
        assertEq(
            l2InteropCenter.accumulatedProtocolFees(coinbaseAddr),
            totalExpectedFees,
            "Accumulated fees should match sum of all bundles"
        );
    }

    /// @notice Test exact fee accounting: ZK fees across multiple bundles
    function test_sendBundle_multipleZKBundlesExactAccounting() public {
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

        address coinbaseAddr = makeAddr("coinbase");
        vm.coinbase(coinbaseAddr);

        address sender = makeAddr("zkFeeSender");
        uint256 zkFeePerCall = l2InteropCenter.ZK_INTEROP_FEE();
        zkToken.mint(sender, zkFeePerCall * 20);

        vm.prank(sender);
        zkToken.approve(L2_INTEROP_CENTER_ADDR, type(uint256).max);

        bytes[] memory bundleAttributes = InteropLibrary.buildBundleAttributes(address(0), UNBUNDLER_ADDRESS, true);

        uint256 senderBalanceBefore = zkToken.balanceOf(sender);

        // Bundle 1: 2 calls
        {
            InteropCallStarter[] memory calls = new InteropCallStarter[](2);
            bytes[] memory callAttributes = new bytes[](0);
            for (uint256 i = 0; i < 2; i++) {
                calls[i] = InteropCallStarter({
                    to: InteroperableAddress.formatEvmV1(interopTargetContract),
                    data: hex"",
                    callAttributes: callAttributes
                });
            }

            vm.prank(sender);
            l2InteropCenter.sendBundle{value: 0}(
                InteroperableAddress.formatEvmV1(destinationChainId),
                calls,
                bundleAttributes
            );
        }

        // Bundle 2: 4 calls
        {
            InteropCallStarter[] memory calls = new InteropCallStarter[](4);
            bytes[] memory callAttributes = new bytes[](0);
            for (uint256 i = 0; i < 4; i++) {
                calls[i] = InteropCallStarter({
                    to: InteroperableAddress.formatEvmV1(interopTargetContract),
                    data: hex"",
                    callAttributes: callAttributes
                });
            }

            vm.prank(sender);
            l2InteropCenter.sendBundle{value: 0}(
                InteroperableAddress.formatEvmV1(destinationChainId),
                calls,
                bundleAttributes
            );
        }

        // Total: 2 + 4 = 6 calls
        uint256 totalExpectedZKFee = zkFeePerCall * 6;
        assertEq(
            l2InteropCenter.accumulatedZKFees(coinbaseAddr),
            totalExpectedZKFee,
            "ZK fees should match exact call count"
        );
        assertEq(
            zkToken.balanceOf(sender),
            senderBalanceBefore - totalExpectedZKFee,
            "Sender balance should decrease by exact fee amount"
        );
        assertEq(
            zkToken.balanceOf(L2_INTEROP_CENTER_ADDR),
            totalExpectedZKFee,
            "InteropCenter should hold exact fee amount"
        );
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
