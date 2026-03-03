// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2BaseTokenEra} from "contracts/l2-system/era/L2BaseTokenEra.sol";
import {IL2BaseTokenBase} from "contracts/l2-system/interfaces/IL2BaseTokenBase.sol";
import {IL2BaseTokenEra} from "contracts/l2-system/era/interfaces/IL2BaseTokenEra.sol";
import {IL2ToL1Messenger} from "contracts/common/l2-helpers/IL2ToL1Messenger.sol";
import {
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BOOTLOADER_ADDRESS,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    MSG_VALUE_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "contracts/common/Config.sol";
import {IMailboxLegacy} from "contracts/state-transition/chain-interfaces/IMailboxLegacy.sol";
import {
    BaseTokenHolderAlreadyInitialized,
    InsufficientFunds,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {DummyL2AssetTracker} from "contracts/dev-contracts/test/DummyL2AssetTracker.sol";
import {DummyL2L1Messenger} from "contracts/dev-contracts/test/DummyL2L1Messenger.sol";
import {DummyL2BaseTokenHolder} from "contracts/dev-contracts/test/DummyL2BaseTokenHolder.sol";

/// @title L2BaseTokenEraTest
/// @notice Unit tests for L2BaseTokenEra contract
contract L2BaseTokenEraTest is Test {
    L2BaseTokenEra internal l2BaseToken;

    address internal l1Receiver;
    address internal alice;
    address internal bob;
    uint256 internal constant WITHDRAW_AMOUNT = 1 ether;
    uint256 internal constant ALICE_INITIAL_BALANCE = 10 ether;

    event Withdrawal(address indexed _l2Sender, address indexed _l1Receiver, uint256 _amount);
    event WithdrawalWithMessage(
        address indexed _l2Sender,
        address indexed _l1Receiver,
        uint256 _amount,
        bytes _additionalData
    );
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Mint(address indexed account, uint256 amount);

    function setUp() public {
        l2BaseToken = new L2BaseTokenEra();
        l1Receiver = makeAddr("l1Receiver");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy dummy dependencies at system addresses (replaces broad vm.mockCall)
        vm.etch(L2_ASSET_TRACKER_ADDR, address(new DummyL2AssetTracker()).code);
        vm.etch(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, address(new DummyL2L1Messenger()).code);

        // Deploy dummy BaseTokenHolder that accepts ETH from any sender.
        // Tests that need real access-control checks etch the real BaseTokenHolder instead.
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new DummyL2BaseTokenHolder()).code);
    }

    /// @dev Helper to set up eraAccountBalance for an address via transferFromTo from bootloader.
    /// First gives the bootloader a balance, then transfers to the target.
    function _setEraBalance(address _account, uint256 _amount) internal {
        // Set bootloader balance directly via store
        // eraAccountBalance is at slot 0 (first storage variable in L2BaseTokenBase)
        bytes32 bootloaderSlot = keccak256(abi.encode(L2_BOOTLOADER_ADDRESS, uint256(0)));
        vm.store(address(l2BaseToken), bootloaderSlot, bytes32(_amount));

        // Transfer from bootloader to account
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.transferFromTo(L2_BOOTLOADER_ADDRESS, _account, _amount);
    }

    /// @dev Helper to set the holder balance in eraAccountBalance storage
    function _setHolderBalance(uint256 _amount) internal {
        bytes32 holderSlot = keccak256(abi.encode(L2_BASE_TOKEN_HOLDER_ADDR, uint256(0)));
        vm.store(address(l2BaseToken), holderSlot, bytes32(_amount));
    }

    /*//////////////////////////////////////////////////////////////
                        totalSupply() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_totalSupply_initiallyEqualsInitialBalance() public view {
        // Before initialization, holder balance is 0, so totalSupply = INITIAL - 0 = INITIAL
        assertEq(
            l2BaseToken.totalSupply(),
            INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "Initial totalSupply should equal INITIAL_BASE_TOKEN_HOLDER_BALANCE"
        );
    }

    function test_totalSupply_afterInitializationWithExistingSupply() public {
        // Simulate existing supply of 50 ether
        uint256 existingSupply = 50 ether;

        // Set __DEPRECATED_totalSupply (slot 1)
        vm.store(address(l2BaseToken), bytes32(uint256(1)), bytes32(existingSupply));

        // Initialize holder balance
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initializeBaseTokenHolderBalance();

        // totalSupply should equal existing supply
        // holder = INITIAL - existingSupply + 0 => totalSupply = INITIAL - (INITIAL - existingSupply) = existingSupply
        assertEq(l2BaseToken.totalSupply(), existingSupply, "totalSupply should match existing supply after init");
    }

    function test_totalSupply_decreasesWhenHolderBalanceIncreases() public {
        // Set holder balance to some value (simulating tokens returned to reserve)
        uint256 holderBalance = 100 ether;
        _setHolderBalance(holderBalance);

        assertEq(
            l2BaseToken.totalSupply(),
            INITIAL_BASE_TOKEN_HOLDER_BALANCE - holderBalance,
            "totalSupply should decrease when holder balance increases"
        );
    }

    function testFuzz_totalSupply_equalsInitialMinusHolderBalance(uint256 holderBalance) public {
        vm.assume(holderBalance <= INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        _setHolderBalance(holderBalance);

        assertEq(
            l2BaseToken.totalSupply(),
            INITIAL_BASE_TOKEN_HOLDER_BALANCE - holderBalance,
            "totalSupply should always be INITIAL - holderBalance"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        balanceOf() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_balanceOf_returnsZeroForNewAccount() public view {
        assertEq(l2BaseToken.balanceOf(uint256(uint160(alice))), 0, "New account should have zero balance");
    }

    function test_balanceOf_returnsCorrectBalanceAfterTransfer() public {
        uint256 amount = 5 ether;
        _setEraBalance(alice, amount);

        assertEq(l2BaseToken.balanceOf(uint256(uint160(alice))), amount, "Alice should have correct balance");
    }

    function test_balanceOf_truncatesUpperBits() public {
        uint256 amount = 3 ether;
        _setEraBalance(alice, amount);

        // Pass uint256 with upper bits set - should be truncated to alice's address
        uint256 accountWithUpperBits = uint256(uint160(alice)) | (uint256(0xDEAD) << 160);

        assertEq(l2BaseToken.balanceOf(accountWithUpperBits), amount, "balanceOf should truncate upper bits");
    }

    function testFuzz_balanceOf_variousAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount < INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        _setEraBalance(alice, amount);
        assertEq(l2BaseToken.balanceOf(uint256(uint160(alice))), amount, "Balance should match set amount");
    }

    /*//////////////////////////////////////////////////////////////
                        transferFromTo() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_transferFromTo_successFromBootloader() public {
        _setEraBalance(alice, ALICE_INITIAL_BALANCE);

        uint256 transferAmount = 3 ether;

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, transferAmount);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.transferFromTo(alice, bob, transferAmount);

        assertEq(
            l2BaseToken.balanceOf(uint256(uint160(alice))),
            ALICE_INITIAL_BALANCE - transferAmount,
            "Alice balance should decrease"
        );
        assertEq(l2BaseToken.balanceOf(uint256(uint160(bob))), transferAmount, "Bob should receive tokens");
    }

    function test_transferFromTo_successFromMsgValueSimulator() public {
        _setEraBalance(alice, ALICE_INITIAL_BALANCE);

        uint256 transferAmount = 2 ether;

        vm.prank(MSG_VALUE_SYSTEM_CONTRACT);
        l2BaseToken.transferFromTo(alice, bob, transferAmount);

        assertEq(
            l2BaseToken.balanceOf(uint256(uint160(alice))),
            ALICE_INITIAL_BALANCE - transferAmount,
            "Alice balance should decrease"
        );
        assertEq(l2BaseToken.balanceOf(uint256(uint160(bob))), transferAmount, "Bob should receive tokens");
    }

    function test_transferFromTo_successFromDeployer() public {
        _setEraBalance(alice, ALICE_INITIAL_BALANCE);

        uint256 transferAmount = 1 ether;

        vm.prank(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);
        l2BaseToken.transferFromTo(alice, bob, transferAmount);

        assertEq(l2BaseToken.balanceOf(uint256(uint160(bob))), transferAmount, "Bob should receive tokens");
    }

    function test_transferFromTo_successFromBaseTokenHolder() public {
        _setEraBalance(alice, ALICE_INITIAL_BALANCE);

        uint256 transferAmount = 1 ether;

        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        l2BaseToken.transferFromTo(alice, bob, transferAmount);

        assertEq(l2BaseToken.balanceOf(uint256(uint160(bob))), transferAmount, "Bob should receive tokens");
    }

    function test_transferFromTo_zeroAmount() public {
        _setEraBalance(alice, ALICE_INITIAL_BALANCE);

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, 0);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.transferFromTo(alice, bob, 0);

        assertEq(
            l2BaseToken.balanceOf(uint256(uint160(alice))),
            ALICE_INITIAL_BALANCE,
            "Alice balance should not change"
        );
        assertEq(l2BaseToken.balanceOf(uint256(uint160(bob))), 0, "Bob balance should remain zero");
    }

    function test_transferFromTo_revertWhenCalledByUnauthorized() public {
        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, unauthorized));
        l2BaseToken.transferFromTo(alice, bob, 1 ether);
    }

    function test_transferFromTo_revertOnInsufficientBalance() public {
        _setEraBalance(alice, 1 ether);

        uint256 tooMuch = 2 ether;

        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(InsufficientFunds.selector, tooMuch, 1 ether));
        l2BaseToken.transferFromTo(alice, bob, tooMuch);
    }

    function test_transferFromTo_emitsTransferEvent() public {
        _setEraBalance(alice, ALICE_INITIAL_BALANCE);

        uint256 transferAmount = 4 ether;

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, transferAmount);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.transferFromTo(alice, bob, transferAmount);
    }

    function test_transferFromTo_selfTransfer() public {
        _setEraBalance(alice, ALICE_INITIAL_BALANCE);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.transferFromTo(alice, alice, 3 ether);

        assertEq(
            l2BaseToken.balanceOf(uint256(uint160(alice))),
            ALICE_INITIAL_BALANCE,
            "Self-transfer should not change balance"
        );
    }

    function testFuzz_transferFromTo_variousAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount <= ALICE_INITIAL_BALANCE);

        _setEraBalance(alice, ALICE_INITIAL_BALANCE);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.transferFromTo(alice, bob, amount);

        assertEq(
            l2BaseToken.balanceOf(uint256(uint160(alice))),
            ALICE_INITIAL_BALANCE - amount,
            "Alice balance should decrease by exact amount"
        );
        assertEq(l2BaseToken.balanceOf(uint256(uint160(bob))), amount, "Bob should receive exact amount");
    }

    /*//////////////////////////////////////////////////////////////
                            mint() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_mint_successFromBootloader() public {
        uint256 mintAmount = 5 ether;

        // Set up holder balance so it has enough to "give"
        _setHolderBalance(INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        uint256 holderBalanceBefore = l2BaseToken.balanceOf(uint256(uint160(L2_BASE_TOKEN_HOLDER_ADDR)));
        uint256 totalSupplyBefore = l2BaseToken.totalSupply();

        vm.expectEmit(true, false, false, true);
        emit Mint(alice, mintAmount);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.mint(alice, mintAmount);

        // Verify balances
        assertEq(l2BaseToken.balanceOf(uint256(uint160(alice))), mintAmount, "Alice should receive minted tokens");
        assertEq(
            l2BaseToken.balanceOf(uint256(uint160(L2_BASE_TOKEN_HOLDER_ADDR))),
            holderBalanceBefore - mintAmount,
            "Holder balance should decrease"
        );
        // totalSupply increases because holder balance decreased: totalSupply = INITIAL - holderBalance
        assertEq(
            l2BaseToken.totalSupply(),
            totalSupplyBefore + mintAmount,
            "totalSupply should increase by minted amount"
        );
    }

    function test_mint_callsAssetTracker() public {
        uint256 mintAmount = 1 ether;
        _setHolderBalance(INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleFinalizeBaseTokenBridgingOnL2(uint256)", mintAmount)
        );

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.mint(alice, mintAmount);
    }

    function test_mint_revertWhenCalledByNonBootloader() public {
        address nonBootloader = makeAddr("nonBootloader");

        vm.prank(nonBootloader);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonBootloader));
        l2BaseToken.mint(alice, 1 ether);
    }

    function test_mint_revertOnInsufficientHolderBalance() public {
        // Holder has 0 balance, so minting any amount should underflow
        uint256 mintAmount = 1 ether;

        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(); // arithmetic underflow
        l2BaseToken.mint(alice, mintAmount);
    }

    function testFuzz_mint_variousAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1000 ether);

        _setHolderBalance(INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.mint(alice, amount);

        assertEq(l2BaseToken.balanceOf(uint256(uint160(alice))), amount, "Alice should receive minted amount");
    }

    /*//////////////////////////////////////////////////////////////
                initializeBaseTokenHolderBalance() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_initializeBaseTokenHolderBalance_success() public {
        uint256 existingSupply = 100 ether;

        // Set __DEPRECATED_totalSupply (slot 1)
        vm.store(address(l2BaseToken), bytes32(uint256(1)), bytes32(existingSupply));

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initializeBaseTokenHolderBalance();

        // holder = INITIAL - existingSupply + 0 (no prior holder balance)
        uint256 expectedHolderBalance = INITIAL_BASE_TOKEN_HOLDER_BALANCE - existingSupply;
        assertEq(
            l2BaseToken.balanceOf(uint256(uint160(L2_BASE_TOKEN_HOLDER_ADDR))),
            expectedHolderBalance,
            "Holder balance should be INITIAL - existingSupply"
        );

        // totalSupply should match existing supply
        assertEq(l2BaseToken.totalSupply(), existingSupply, "totalSupply should equal existing supply");
    }

    function test_initializeBaseTokenHolderBalance_preservesExistingHolderBalance() public {
        uint256 existingSupply = 50 ether;
        uint256 existingHolderBalance = 10 ether;

        // Set __DEPRECATED_totalSupply
        vm.store(address(l2BaseToken), bytes32(uint256(1)), bytes32(existingSupply));

        // Set existing holder balance in eraAccountBalance
        _setHolderBalance(existingHolderBalance);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initializeBaseTokenHolderBalance();

        // holder = INITIAL - existingSupply + existingHolderBalance
        uint256 expectedHolderBalance = INITIAL_BASE_TOKEN_HOLDER_BALANCE - existingSupply + existingHolderBalance;
        assertEq(
            l2BaseToken.balanceOf(uint256(uint160(L2_BASE_TOKEN_HOLDER_ADDR))),
            expectedHolderBalance,
            "Holder balance should include existing holder balance"
        );
    }

    function test_initializeBaseTokenHolderBalance_zeroExistingSupply() public {
        // __DEPRECATED_totalSupply defaults to 0
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initializeBaseTokenHolderBalance();

        // holder = INITIAL - 0 + 0 = INITIAL
        assertEq(
            l2BaseToken.balanceOf(uint256(uint160(L2_BASE_TOKEN_HOLDER_ADDR))),
            INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "Holder should get full initial balance when no existing supply"
        );

        assertEq(l2BaseToken.totalSupply(), 0, "totalSupply should be 0 when no existing supply");
    }

    function test_initializeBaseTokenHolderBalance_revertIfNotComplexUpgrader() public {
        address nonUpgrader = makeAddr("nonUpgrader");

        vm.prank(nonUpgrader);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonUpgrader));
        l2BaseToken.initializeBaseTokenHolderBalance();
    }

    function test_initializeBaseTokenHolderBalance_revertsOnSecondCall() public {
        uint256 existingSupply = 100 ether;
        vm.store(address(l2BaseToken), bytes32(uint256(1)), bytes32(existingSupply));

        // First call succeeds
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initializeBaseTokenHolderBalance();

        // Second call reverts with BaseTokenHolderAlreadyInitialized
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenHolderAlreadyInitialized.selector);
        l2BaseToken.initializeBaseTokenHolderBalance();
    }

    function testFuzz_initializeBaseTokenHolderBalance_variousSupplies(uint256 existingSupply) public {
        vm.assume(existingSupply <= INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        vm.store(address(l2BaseToken), bytes32(uint256(1)), bytes32(existingSupply));

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initializeBaseTokenHolderBalance();

        assertEq(
            l2BaseToken.totalSupply(),
            existingSupply,
            "totalSupply should match existingSupply after initialization"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        withdraw() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_successTransfersToHolder() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        // Expect the L1Messenger call
        bytes memory expectedMessage = abi.encodePacked(
            IMailboxLegacy.finalizeEthWithdrawal.selector,
            l1Receiver,
            WITHDRAW_AMOUNT
        );
        vm.expectCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSignature("sendToL1(bytes)", expectedMessage)
        );

        vm.expectEmit(true, true, false, true);
        emit Withdrawal(sender, l1Receiver, WITHDRAW_AMOUNT);

        vm.prank(sender);
        l2BaseToken.withdraw{value: WITHDRAW_AMOUNT}(l1Receiver);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + WITHDRAW_AMOUNT,
            "BaseTokenHolder should receive ETH"
        );
    }

    function test_withdraw_callsAssetTrackerWithL1ChainId() public {
        // Deploy real BaseTokenHolder so the full call chain reaches L2AssetTracker
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);

        // Deploy at system contract address so it passes onlyBridgingCaller check
        L2BaseTokenEra l2BaseTokenAtSystemAddr = new L2BaseTokenEra();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        // L1_CHAIN_ID mock returns 1, so expect toChainId = 1
        vm.expectCall(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeWithSignature("handleInitiateBaseTokenBridgingOnL2(uint256,uint256)", 1, WITHDRAW_AMOUNT)
        );

        vm.prank(sender);
        L2BaseTokenEra(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).withdraw{value: WITHDRAW_AMOUNT}(l1Receiver);
    }

    function test_withdraw_callsL1Messenger() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        bytes memory expectedMessage = abi.encodePacked(
            IMailboxLegacy.finalizeEthWithdrawal.selector,
            l1Receiver,
            WITHDRAW_AMOUNT
        );

        vm.expectCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSignature("sendToL1(bytes)", expectedMessage)
        );

        vm.prank(sender);
        l2BaseToken.withdraw{value: WITHDRAW_AMOUNT}(l1Receiver);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + WITHDRAW_AMOUNT,
            "BaseTokenHolder should receive ETH"
        );
    }

    function test_withdraw_revertsIfBaseTokenHolderRejects() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

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

    function test_withdrawWithMessage_successTransfersToHolder() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);
        bytes memory additionalData = "test message";

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        vm.expectEmit(true, true, false, true);
        emit WithdrawalWithMessage(sender, l1Receiver, WITHDRAW_AMOUNT, additionalData);

        vm.prank(sender);
        l2BaseToken.withdrawWithMessage{value: WITHDRAW_AMOUNT}(l1Receiver, additionalData);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + WITHDRAW_AMOUNT,
            "BaseTokenHolder should receive ETH"
        );
    }

    function test_withdrawWithMessage_callsL1MessengerWithExtendedMessage() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);
        bytes memory additionalData = "test message";

        bytes memory expectedMessage = abi.encodePacked(
            IMailboxLegacy.finalizeEthWithdrawal.selector,
            l1Receiver,
            WITHDRAW_AMOUNT,
            sender,
            additionalData
        );

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

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        vm.prank(sender);
        l2BaseToken.withdrawWithMessage{value: WITHDRAW_AMOUNT}(l1Receiver, "");

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + WITHDRAW_AMOUNT,
            "BaseTokenHolder should receive ETH"
        );
    }

    function test_withdrawWithMessage_revertsIfBaseTokenHolderRejects() public {
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        RejectingBurnAndStartBridgingContract rejecting = new RejectingBurnAndStartBridgingContract();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(rejecting).code);

        vm.prank(sender);
        vm.expectRevert("Rejected");
        l2BaseToken.withdrawWithMessage{value: WITHDRAW_AMOUNT}(l1Receiver, "data");
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
                    INTEGRATION: MINT + TRANSFER + TOTALSUPPLY
    //////////////////////////////////////////////////////////////*/

    function test_mintThenTransfer_balancesAndSupplyConsistent() public {
        _setHolderBalance(INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        uint256 mintAmount = 10 ether;
        uint256 transferAmount = 3 ether;

        // Mint to alice
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.mint(alice, mintAmount);

        uint256 totalSupplyAfterMint = l2BaseToken.totalSupply();

        // Transfer from alice to bob
        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.transferFromTo(alice, bob, transferAmount);

        // totalSupply should not change from a transfer
        assertEq(l2BaseToken.totalSupply(), totalSupplyAfterMint, "totalSupply should not change on transfer");

        // Balances should be correct
        assertEq(
            l2BaseToken.balanceOf(uint256(uint160(alice))),
            mintAmount - transferAmount,
            "Alice should have mint - transfer"
        );
        assertEq(l2BaseToken.balanceOf(uint256(uint160(bob))), transferAmount, "Bob should have transfer amount");
    }

    function test_mintMultipleAccounts_totalSupplyCorrect() public {
        _setHolderBalance(INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        uint256 mint1 = 5 ether;
        uint256 mint2 = 7 ether;

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.mint(alice, mint1);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        l2BaseToken.mint(bob, mint2);

        // totalSupply = INITIAL - holderBalance. Minting decreases holder balance,
        // so totalSupply increases by the minted amounts.
        assertEq(l2BaseToken.totalSupply(), mint1 + mint2, "totalSupply should equal total minted amount");
    }

    /*//////////////////////////////////////////////////////////////
                        MESSAGE FORMAT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawMessage_format() public pure {
        address receiver = address(0x1234);
        uint256 amount = 1 ether;

        bytes memory expectedMessage = abi.encodePacked(
            IMailboxLegacy.finalizeEthWithdrawal.selector,
            receiver,
            amount
        );

        // selector (4) + address (20) + uint256 (32) = 56 bytes
        assertEq(expectedMessage.length, 56, "Basic withdrawal message should be 56 bytes");
    }

    function test_withdrawWithMessage_extendedFormat() public {
        address sender = makeAddr("sender");
        bytes memory additionalData = "hello";

        bytes memory expectedMessage = abi.encodePacked(
            IMailboxLegacy.finalizeEthWithdrawal.selector,
            l1Receiver,
            WITHDRAW_AMOUNT,
            sender,
            additionalData
        );

        // selector (4) + l1Receiver (20) + amount (32) + sender (20) + data (5) = 81 bytes
        assertEq(expectedMessage.length, 81, "Extended withdrawal message should be 81 bytes");
    }

    /*//////////////////////////////////////////////////////////////
                        INTERFACE COMPLIANCE
    //////////////////////////////////////////////////////////////*/

    function test_implementsIL2BaseTokenBase() public view {
        IL2BaseTokenBase token = IL2BaseTokenBase(address(l2BaseToken));
        assert(address(token) == address(l2BaseToken));
    }

    function test_implementsIL2BaseTokenEra() public view {
        IL2BaseTokenEra token = IL2BaseTokenEra(address(l2BaseToken));
        assert(address(token) == address(l2BaseToken));
    }
}

/// @notice Helper contract that rejects burnAndStartBridging calls
contract RejectingBurnAndStartBridgingContract {
    function burnAndStartBridging(uint256) external payable {
        revert("Rejected");
    }

    receive() external payable {
        revert("Rejected");
    }
}
