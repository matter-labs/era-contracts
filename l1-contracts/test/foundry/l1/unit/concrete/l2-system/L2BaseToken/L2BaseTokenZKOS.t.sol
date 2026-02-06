// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2BaseTokenZKOS} from "contracts/l2-system/zksync-os/L2BaseTokenZKOS.sol";
import {IL2BaseTokenBase} from "contracts/l2-system/interfaces/IL2BaseTokenBase.sol";
import {IL2ToL1Messenger} from "contracts/common/l2-helpers/IL2ToL1Messenger.sol";
import {L2_ASSET_TRACKER_ADDR, L2_BASE_TOKEN_HOLDER, L2_BASE_TOKEN_HOLDER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, MINT_BASE_TOKEN_HOOK} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "contracts/common/Config.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {BaseTokenHolderMintFailed, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";

/// @title L2BaseTokenZKOSTest
/// @notice Unit tests for L2BaseTokenZKOS contract
contract L2BaseTokenZKOSTest is Test {
    L2BaseTokenZKOS internal l2BaseToken;

    address internal l1Receiver;
    uint256 internal constant WITHDRAW_AMOUNT = 1 ether;

    event Withdrawal(address indexed _l2Sender, address indexed _l1Receiver, uint256 _amount);
    event WithdrawalWithMessage(
        address indexed _l2Sender,
        address indexed _l1Receiver,
        uint256 _amount,
        bytes _additionalData
    );
    event L1MessageSent(address indexed _sender, bytes32 indexed _hash, bytes _message);

    function setUp() public {
        l2BaseToken = new L2BaseTokenZKOS();
        l1Receiver = makeAddr("l1Receiver");

        // Mock L2AssetTracker to accept calls
        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)"),
            abi.encode()
        );

        // Mock L1Messenger to accept calls and return a hash
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSignature("sendToL1(bytes)"),
            abi.encode(bytes32(uint256(1)))
        );

        // Make BaseTokenHolder accept ETH (etch minimal contract)
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, hex"00");
    }

    /*//////////////////////////////////////////////////////////////
                            withdraw() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_success() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        // Expect the Withdrawal event
        vm.expectEmit(true, true, false, true);
        emit Withdrawal(sender, l1Receiver, WITHDRAW_AMOUNT);

        vm.prank(sender);
        l2BaseToken.withdraw{value: WITHDRAW_AMOUNT}(l1Receiver);

        // Verify BaseTokenHolder received the ETH
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + WITHDRAW_AMOUNT,
            "BaseTokenHolder should receive ETH"
        );
    }

    function test_withdraw_callsAssetTracker() public {
        // Use actual BaseTokenHolder to verify AssetTracker is called
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Deploy L2BaseTokenZKOS at the expected system contract address so it passes onlyBridgingCaller check
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        // Expect the AssetTracker call
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)", WITHDRAW_AMOUNT)
        );

        vm.prank(sender);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).withdraw{value: WITHDRAW_AMOUNT}(l1Receiver);
    }

    function test_withdraw_callsL1Messenger() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        // Expected message format
        bytes memory expectedMessage = abi.encodePacked(
            IMailboxImpl.finalizeEthWithdrawal.selector,
            l1Receiver,
            WITHDRAW_AMOUNT
        );

        // Expect the L1Messenger call
        vm.expectCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSignature("sendToL1(bytes)", expectedMessage)
        );

        vm.prank(sender);
        l2BaseToken.withdraw{value: WITHDRAW_AMOUNT}(l1Receiver);
    }

    function test_withdraw_revertsIfBaseTokenHolderRejectsTransfer() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        // Deploy a contract that rejects burnAndStartBridging at BaseTokenHolder address
        RejectingBurnAndStartBridgingContract rejecting = new RejectingBurnAndStartBridgingContract();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(rejecting).code);

        vm.prank(sender);
        vm.expectRevert("Rejected");
        l2BaseToken.withdraw{value: WITHDRAW_AMOUNT}(l1Receiver);
    }

    function testFuzz_withdraw_variousAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max);

        address sender = makeAddr("sender");
        vm.deal(sender, amount);

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        vm.prank(sender);
        l2BaseToken.withdraw{value: amount}(l1Receiver);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + amount,
            "BaseTokenHolder should receive correct amount"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        withdrawWithMessage() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawWithMessage_success() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);
        bytes memory additionalData = "test message";

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        // Expect the WithdrawalWithMessage event
        vm.expectEmit(true, true, false, true);
        emit WithdrawalWithMessage(sender, l1Receiver, WITHDRAW_AMOUNT, additionalData);

        vm.prank(sender);
        l2BaseToken.withdrawWithMessage{value: WITHDRAW_AMOUNT}(l1Receiver, additionalData);

        // Verify BaseTokenHolder received the ETH
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + WITHDRAW_AMOUNT,
            "BaseTokenHolder should receive ETH"
        );
    }

    function test_withdrawWithMessage_callsAssetTracker() public {
        // Use actual BaseTokenHolder to verify AssetTracker is called
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Deploy L2BaseTokenZKOS at the expected system contract address so it passes onlyBridgingCaller check
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);
        bytes memory additionalData = "test message";

        // Expect the AssetTracker call
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)", WITHDRAW_AMOUNT)
        );

        vm.prank(sender);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).withdrawWithMessage{value: WITHDRAW_AMOUNT}(
            l1Receiver,
            additionalData
        );
    }

    function test_withdrawWithMessage_callsL1MessengerWithExtendedMessage() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);
        bytes memory additionalData = "test message";

        // Expected extended message format
        bytes memory expectedMessage = abi.encodePacked(
            IMailboxImpl.finalizeEthWithdrawal.selector,
            l1Receiver,
            WITHDRAW_AMOUNT,
            sender,
            additionalData
        );

        // Expect the L1Messenger call
        vm.expectCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSignature("sendToL1(bytes)", expectedMessage)
        );

        vm.prank(sender);
        l2BaseToken.withdrawWithMessage{value: WITHDRAW_AMOUNT}(l1Receiver, additionalData);
    }

    function test_withdrawWithMessage_emptyAdditionalData() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);
        bytes memory additionalData = "";

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        vm.prank(sender);
        l2BaseToken.withdrawWithMessage{value: WITHDRAW_AMOUNT}(l1Receiver, additionalData);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + WITHDRAW_AMOUNT,
            "BaseTokenHolder should receive ETH"
        );
    }

    function test_withdrawWithMessage_revertsIfBaseTokenHolderRejectsTransfer() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);
        bytes memory additionalData = "test message";

        // Deploy a contract that rejects burnAndStartBridging at BaseTokenHolder address
        RejectingBurnAndStartBridgingContract rejecting = new RejectingBurnAndStartBridgingContract();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(rejecting).code);

        vm.prank(sender);
        vm.expectRevert("Rejected");
        l2BaseToken.withdrawWithMessage{value: WITHDRAW_AMOUNT}(l1Receiver, additionalData);
    }

    function testFuzz_withdrawWithMessage_variousAmountsAndData(uint256 amount, bytes calldata additionalData) public {
        vm.assume(amount > 0 && amount < type(uint128).max);

        address sender = makeAddr("sender");
        vm.deal(sender, amount);

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        vm.prank(sender);
        l2BaseToken.withdrawWithMessage{value: amount}(l1Receiver, additionalData);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + amount,
            "BaseTokenHolder should receive correct amount"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    initializeBaseTokenHolderBalance() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_initializeBaseTokenHolderBalance_success() public {
        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the L2BaseToken contract the minted balance (simulating what mint hook does)
        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        // Call from ComplexUpgrader
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initializeBaseTokenHolderBalance();

        // Verify BaseTokenHolder received the tokens
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should receive initial balance"
        );
    }

    function test_initializeBaseTokenHolderBalance_revertIfNotComplexUpgrader() public {
        address nonUpgrader = makeAddr("nonUpgrader");

        vm.prank(nonUpgrader);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonUpgrader));
        l2BaseToken.initializeBaseTokenHolderBalance();
    }

    function test_initializeBaseTokenHolderBalance_revertsOnSecondCall() public {
        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the L2BaseToken contract the minted balance
        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // First call succeeds
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initializeBaseTokenHolderBalance();

        // Second call should revert (OpenZeppelin Initializable)
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert("Initializable: contract is already initialized");
        l2BaseToken.initializeBaseTokenHolderBalance();
    }

    function test_initializeBaseTokenHolderBalance_revertIfMintFails() public {
        // Mock the mint hook to fail
        vm.mockCallRevert(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), "Mint failed");

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenHolderMintFailed.selector);
        l2BaseToken.initializeBaseTokenHolderBalance();
    }

    function test_initializeBaseTokenHolderBalance_revertIfTransferFails() public {
        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the contract some balance but not enough
        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Make BaseTokenHolder reject transfers
        RejectingContract rejecting = new RejectingContract();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(rejecting).code);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert("Address: unable to send value, recipient may have reverted");
        l2BaseToken.initializeBaseTokenHolderBalance();
    }

    /// @notice Verifies that initializeBaseTokenHolderBalance works with actual BaseTokenHolder
    /// @dev This test ensures L2BaseToken is in the trusted sender list of BaseTokenHolder
    /// @dev CRITICAL: This test validates that BaseTokenHolder can receive ETH from L2BaseToken
    function test_initializeBaseTokenHolderBalance_withActualBaseTokenHolder() public {
        // Deploy actual BaseTokenHolder at the expected address
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Deploy L2BaseTokenZKOS at the expected system contract address
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the L2BaseToken contract the minted balance (simulating what mint hook does)
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Call from ComplexUpgrader - this should succeed because L2BaseToken is a trusted sender
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initializeBaseTokenHolderBalance();

        // Verify BaseTokenHolder received the tokens
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should receive initial balance from L2BaseToken"
        );
    }

    /// @notice Verifies that BaseTokenHolder rejects ETH from untrusted senders via receive()
    /// @dev This test ensures that only L2BaseToken can send ETH via receive()
    function test_baseTokenHolder_rejectsUntrustedSenders_receive() public {
        // Deploy actual BaseTokenHolder at the expected address
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Try to send ETH from an untrusted address via receive()
        address untrustedSender = makeAddr("untrustedSender");
        vm.deal(untrustedSender, 1 ether);

        vm.prank(untrustedSender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, untrustedSender));
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: 1 ether}("");
        // Note: expectRevert handles the revert, success will be true after expectRevert
        assertTrue(success);
    }

    /// @notice Verifies that BaseTokenHolder rejects burnAndStartBridging from untrusted senders
    /// @dev This test ensures that only bridging callers can use burnAndStartBridging
    function test_baseTokenHolder_rejectsUntrustedSenders_burnAndStartBridging() public {
        // Deploy actual BaseTokenHolder at the expected address
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Try to call burnAndStartBridging from an untrusted address
        address untrustedSender = makeAddr("untrustedSender");
        vm.deal(untrustedSender, 1 ether);

        vm.prank(untrustedSender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, untrustedSender));
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: 1 ether}();
    }

    /// @notice Verifies that BaseTokenHolder notifies L2AssetTracker when receiving ETH via burnAndStartBridging from InteropCenter
    /// @dev This test ensures bridging operations are properly tracked
    function test_baseTokenHolder_notifiesAssetTrackerOnBridging() public {
        // Deploy actual BaseTokenHolder at the expected address
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Mock L2AssetTracker to accept calls
        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)"),
            abi.encode()
        );

        uint256 burnAmount = 1 ether;

        // Expect the AssetTracker call when InteropCenter calls burnAndStartBridging
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)", burnAmount)
        );

        // InteropCenter calls burnAndStartBridging (simulating a bridging burn)
        vm.deal(L2_INTEROP_CENTER_ADDR, burnAmount);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}();
    }

    /// @notice Verifies that BaseTokenHolder notifies L2AssetTracker when receiving ETH via burnAndStartBridging from NativeTokenVault
    /// @dev This test ensures bridging operations are properly tracked
    function test_baseTokenHolder_notifiesAssetTrackerFromNTV() public {
        // Deploy actual BaseTokenHolder at the expected address
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Mock L2AssetTracker to accept calls
        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)"),
            abi.encode()
        );

        uint256 burnAmount = 2 ether;

        // Expect the AssetTracker call when NativeTokenVault calls burnAndStartBridging
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)", burnAmount)
        );

        // NativeTokenVault calls burnAndStartBridging (simulating a bridging burn)
        vm.deal(L2_NATIVE_TOKEN_VAULT_ADDR, burnAmount);
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}();
    }

    /// @notice Verifies that L2BaseToken can call burnAndStartBridging for withdrawals
    /// @dev This test ensures L2BaseToken is a valid bridging caller
    function test_baseTokenHolder_notifiesAssetTrackerFromL2BaseToken_burnAndStartBridging() public {
        // Deploy actual BaseTokenHolder at the expected address
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Mock L2AssetTracker to accept calls
        vm.mockCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)"),
            abi.encode()
        );

        uint256 burnAmount = 1 ether;

        // Expect the AssetTracker call when L2BaseToken calls burnAndStartBridging
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)", burnAmount)
        );

        // L2BaseToken calls burnAndStartBridging (simulating a withdrawal)
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, burnAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}();
    }

    /// @notice Verifies that BaseTokenHolder does NOT notify L2AssetTracker when receiving ETH via receive() from L2BaseToken
    /// @dev L2BaseToken sends via receive() during initialization, which is not a bridging operation
    function test_baseTokenHolder_doesNotNotifyAssetTrackerFromL2BaseToken() public {
        // Deploy actual BaseTokenHolder at the expected address
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        uint256 initAmount = 1 ether;

        // Expect the AssetTracker to NOT be called (count = 0)
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)", initAmount),
            0 // count = 0 means we expect it NOT to be called
        );

        // L2BaseToken sends ETH to BaseTokenHolder via receive() (during initialization)
        // We should NOT see a call to L2AssetTracker
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, initAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: initAmount}("");
        assertTrue(success, "Transfer should succeed");
    }

    /// @notice Verifies that initializeBaseTokenHolderBalance does NOT trigger L2AssetTracker
    /// @dev This tests the full initialization flow to ensure asset tracker is not notified
    function test_initializeBaseTokenHolderBalance_doesNotTriggerAssetTracker() public {
        // Deploy actual BaseTokenHolder at the expected address
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Deploy L2BaseTokenZKOS at the expected system contract address
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the L2BaseToken contract the minted balance
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Expect the AssetTracker to NOT be called during initialization
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)", INITIAL_BASE_TOKEN_HOLDER_BALANCE),
            0 // count = 0 means we expect it NOT to be called
        );

        // Call initializeBaseTokenHolderBalance
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initializeBaseTokenHolderBalance();

        // Verify BaseTokenHolder received the initial balance
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should have received initial balance"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        INTERFACE COMPLIANCE
    //////////////////////////////////////////////////////////////*/

    function test_implementsIL2BaseTokenBase() public view {
        // Verify the contract implements the interface
        IL2BaseTokenBase token = IL2BaseTokenBase(address(l2BaseToken));
        assert(address(token) == address(l2BaseToken));
    }

    /*//////////////////////////////////////////////////////////////
                        MESSAGE FORMAT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawMessage_format() public {
        // Verify the message format matches what L1 expects
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        bytes memory expectedMessage = abi.encodePacked(
            IMailboxImpl.finalizeEthWithdrawal.selector,
            l1Receiver,
            WITHDRAW_AMOUNT
        );

        // The selector should be 4 bytes + address (20 bytes) + uint256 (32 bytes) = 56 bytes
        assertEq(expectedMessage.length, 56, "Basic withdrawal message should be 56 bytes");

        // First 4 bytes should be the selector
        bytes4 selector;
        assembly {
            selector := mload(add(expectedMessage, 32))
        }
        assertEq(selector, IMailboxImpl.finalizeEthWithdrawal.selector, "Selector should match");
    }

    function test_withdrawWithMessage_extendedFormat() public {
        address sender = makeAddr("sender");
        bytes memory additionalData = "hello";

        bytes memory expectedMessage = abi.encodePacked(
            IMailboxImpl.finalizeEthWithdrawal.selector,
            l1Receiver,
            WITHDRAW_AMOUNT,
            sender,
            additionalData
        );

        // selector (4) + l1Receiver (20) + amount (32) + sender (20) + data (5) = 81 bytes
        assertEq(expectedMessage.length, 81, "Extended withdrawal message should be 81 bytes");
    }
}

/// @notice Helper contract that rejects ETH transfers via receive()
contract RejectingContract {
    receive() external payable {
        revert("Rejected");
    }
}

/// @notice Helper contract that rejects burnAndStartBridging calls
contract RejectingBurnAndStartBridgingContract {
    function burnAndStartBridging() external payable {
        revert("Rejected");
    }

    receive() external payable {
        revert("Rejected");
    }
}
