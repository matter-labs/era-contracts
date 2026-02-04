// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2BaseTokenZKOS} from "contracts/l2-system/zksync-os/L2BaseTokenZKOS.sol";
import {IL2BaseTokenZKOS} from "contracts/l2-system/zksync-os/interfaces/IL2BaseTokenZKOS.sol";
import {IL2ToL1MessengerZKSyncOS} from "contracts/common/l2-helpers/IL2ToL1MessengerZKSyncOS.sol";
import {L2_ASSET_TRACKER_ADDR, L2_BASE_TOKEN_HOLDER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, MINT_BASE_TOKEN_HOOK} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "contracts/common/Config.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {BaseTokenHolderMintFailed, BaseTokenHolderTransferFailed, Unauthorized, WithdrawFailed} from "contracts/common/L1ContractErrors.sol";

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
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        // Expect the AssetTracker call
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)", WITHDRAW_AMOUNT)
        );

        vm.prank(sender);
        l2BaseToken.withdraw{value: WITHDRAW_AMOUNT}(l1Receiver);
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
        vm.expectCall(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, abi.encodeWithSignature("sendToL1(bytes)", expectedMessage));

        vm.prank(sender);
        l2BaseToken.withdraw{value: WITHDRAW_AMOUNT}(l1Receiver);
    }

    function test_withdraw_revertsIfBaseTokenHolderRejectsTransfer() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        // Deploy a contract that rejects ETH at BaseTokenHolder address
        RejectingContract rejecting = new RejectingContract();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(rejecting).code);

        vm.prank(sender);
        vm.expectRevert(WithdrawFailed.selector);
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
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);
        bytes memory additionalData = "test message";

        // Expect the AssetTracker call
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256)", WITHDRAW_AMOUNT)
        );

        vm.prank(sender);
        l2BaseToken.withdrawWithMessage{value: WITHDRAW_AMOUNT}(l1Receiver, additionalData);
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
        vm.expectCall(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, abi.encodeWithSignature("sendToL1(bytes)", expectedMessage));

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

        // Deploy a contract that rejects ETH at BaseTokenHolder address
        RejectingContract rejecting = new RejectingContract();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(rejecting).code);

        vm.prank(sender);
        vm.expectRevert(WithdrawFailed.selector);
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

        // Verify initialized flag is set
        assertTrue(l2BaseToken.initialized(), "Should be initialized");

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

    function test_initializeBaseTokenHolderBalance_idempotent() public {
        // Mock the mint hook to succeed
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // Give the L2BaseToken contract the minted balance
        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // First call
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initializeBaseTokenHolderBalance();

        uint256 holderBalanceAfterFirst = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        // Second call should be a no-op
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initializeBaseTokenHolderBalance();

        // Balance should not change
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceAfterFirst,
            "Balance should not change on second call"
        );
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
        vm.expectRevert(BaseTokenHolderTransferFailed.selector);
        l2BaseToken.initializeBaseTokenHolderBalance();
    }

    function test_initializedFlag_defaultFalse() public view {
        assertFalse(l2BaseToken.initialized(), "Should not be initialized by default");
    }

    /*//////////////////////////////////////////////////////////////
                        INTERFACE COMPLIANCE
    //////////////////////////////////////////////////////////////*/

    function test_implementsIL2BaseTokenZKOS() public view {
        // Verify the contract implements the interface
        IL2BaseTokenZKOS token = IL2BaseTokenZKOS(address(l2BaseToken));
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

/// @notice Helper contract that rejects ETH transfers
contract RejectingContract {
    receive() external payable {
        revert("Rejected");
    }
}
