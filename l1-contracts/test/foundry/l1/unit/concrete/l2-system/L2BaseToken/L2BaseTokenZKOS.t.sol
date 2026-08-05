// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2BaseTokenZKOS} from "contracts/l2-system/zksync-os/L2BaseTokenZKOS.sol";
import {IL2BaseTokenBase} from "contracts/l2-system/interfaces/IL2BaseTokenBase.sol";
import {IL2BaseTokenZKOS} from "contracts/l2-system/zksync-os/interfaces/IL2BaseTokenZKOS.sol";
import {IL2ToL1Messenger} from "contracts/common/l2-helpers/IL2ToL1Messenger.sol";
import {
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    MINT_BASE_TOKEN_HOOK
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_BASE_TOKEN_HOLDER} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE, SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {IMailboxLegacy} from "contracts/state-transition/chain-interfaces/IMailboxLegacy.sol";
import {
    BaseTokenHolderAlreadyInitialized,
    BaseTokenBookkeepingAlreadyInitialized,
    BaseTokenHolderMintFailed,
    BaseTokenPreV31TotalSupplyAlreadySet,
    BaseTokenPreV31TotalSupplyNotSet,
    BaseTokenTotalSupplyBackfillNotNeeded,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {SavedTotalSupply} from "contracts/common/L2AssetBookkeeping.sol";
import {ISystemContext} from "contracts/common/interfaces/ISystemContext.sol";
import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {DummyL2L1Messenger} from "contracts/dev-contracts/test/DummyL2L1Messenger.sol";
import {DummyL2BaseTokenHolder} from "contracts/dev-contracts/test/DummyL2BaseTokenHolder.sol";

/// @title L2BaseTokenZKOSTest
/// @notice Unit tests for L2BaseTokenZKOS (init, pre-V31 total-supply backfill, totalSupply).
/// See {protocol-docs/bridging.md#l2-asset-bookkeeping}.
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

        // Deploy dummy dependencies at system addresses (replaces broad vm.mockCall)
        vm.etch(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, address(new DummyL2L1Messenger()).code);

        // Deploy dummy BaseTokenHolder that accepts ETH from any sender.
        // Tests that need real access-control checks etch the real BaseTokenHolder instead.
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new DummyL2BaseTokenHolder()).code);

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.L1_CHAIN_ID.selector),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(ISystemContext.currentSettlementLayerChainId.selector),
            abi.encode(uint256(1))
        );
    }

    function _initializeBackfill(L2BaseTokenZKOS _token, bool _needsBackfill) internal {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        _token.initializeTotalSupplyBackfill(_needsBackfill);
    }

    /// @dev Helper to initialize l2BaseToken via initL2() — sets L1_CHAIN_ID and transfers to BaseTokenHolder.
    function _initL2() internal {
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());
        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initL2(1);
    }

    /*//////////////////////////////////////////////////////////////
                            withdraw() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_success() public {
        _initL2();
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

    function test_withdraw_recordsBaseTokenBookkeeping() public {
        // Use the actual holder to verify the withdrawal counter.
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Deploy L2BaseTokenZKOS at the expected system contract address so it passes onlyBridgingCaller check
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);
        // Initialize L1_CHAIN_ID on the system-address instance via initL2()
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(1);

        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        vm.prank(sender);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).withdraw{value: WITHDRAW_AMOUNT}(l1Receiver);

        (uint256 withdrawals, ) = L2_BASE_TOKEN_HOLDER.baseTokenInteropInfo();
        assertEq(withdrawals, WITHDRAW_AMOUNT, "withdrawal should be recorded by the holder");
    }

    function test_withdraw_callsL1Messenger() public {
        _initL2();
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        // Expected message format
        bytes memory expectedMessage = abi.encodePacked(
            IMailboxLegacy.finalizeEthWithdrawal.selector,
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

        // Verify BaseTokenHolder received the ETH
        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + WITHDRAW_AMOUNT,
            "BaseTokenHolder should receive ETH"
        );
    }

    function test_withdraw_revertsIfBaseTokenHolderRejectsTransfer() public {
        _initL2();
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
        _initL2();
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
        _initL2();
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

    function test_withdrawWithMessage_recordsBaseTokenBookkeeping() public {
        // Use the actual holder to verify the withdrawal counter.
        BaseTokenHolder baseTokenHolder = new BaseTokenHolder();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(baseTokenHolder).code);

        // Deploy L2BaseTokenZKOS at the expected system contract address so it passes onlyBridgingCaller check
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);
        // Initialize L1_CHAIN_ID on the system-address instance via initL2()
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(1);

        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);
        bytes memory additionalData = "test message";

        vm.prank(sender);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).withdrawWithMessage{value: WITHDRAW_AMOUNT}(
            l1Receiver,
            additionalData
        );

        (uint256 withdrawals, ) = L2_BASE_TOKEN_HOLDER.baseTokenInteropInfo();
        assertEq(withdrawals, WITHDRAW_AMOUNT, "withdrawal should be recorded by the holder");
    }

    function test_withdrawWithMessage_callsL1MessengerWithExtendedMessage() public {
        _initL2();
        address sender = makeAddr("sender");
        vm.deal(sender, WITHDRAW_AMOUNT);
        bytes memory additionalData = "test message";

        // Expected extended message format
        bytes memory expectedMessage = abi.encodePacked(
            IMailboxLegacy.finalizeEthWithdrawal.selector,
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
        _initL2();
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
        _initL2();
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
        _initL2();
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
                    initL2() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_initL2_success() public {
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // The mocked mint hook does not actually mint, so fund the contract manually.
        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initL2(1);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            holderBalanceBefore + INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should receive initial balance"
        );
    }

    function test_initL2_revertIfNotComplexUpgrader() public {
        address nonUpgrader = makeAddr("nonUpgrader");

        vm.prank(nonUpgrader);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonUpgrader));
        l2BaseToken.initL2(1);
    }

    function test_initL2_revertsOnSecondCall() public {
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2BaseToken.initL2(1);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenHolderAlreadyInitialized.selector);
        l2BaseToken.initL2(1);
    }

    function test_initL2_revertIfMintFails() public {
        vm.mockCallRevert(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), "Mint failed");

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenHolderMintFailed.selector);
        l2BaseToken.initL2(1);
    }

    function test_initL2_revertIfTransferFails() public {
        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        vm.deal(address(l2BaseToken), INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        RejectingContract rejecting = new RejectingContract();
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(rejecting).code);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert("Address: unable to send value, recipient may have reverted");
        l2BaseToken.initL2(1);
    }

    /// @notice initL2 works against the real BaseTokenHolder: L2BaseToken must be a trusted sender.
    function test_initL2_withActualBaseTokenHolder() public {
        // Deploy real BaseTokenHolder for this integration test
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);

        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        // The mocked mint hook does not actually mint, so fund the contract manually.
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(1);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should receive initial balance from L2BaseToken"
        );
    }

    /// @notice BaseTokenHolder rejects receive() from untrusted senders.
    function test_baseTokenHolder_rejectsUntrustedSenders_receive() public {
        // Deploy real BaseTokenHolder for access-control tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        address untrustedSender = makeAddr("untrustedSender");
        vm.deal(untrustedSender, 1 ether);

        vm.prank(untrustedSender);
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: 1 ether}("");
        assertFalse(success, "Transfer should fail from untrusted sender");
    }

    /// @notice BaseTokenHolder rejects burnAndStartBridging from non-bridging callers.
    function test_baseTokenHolder_rejectsUntrustedSenders_burnAndStartBridging() public {
        // Deploy real BaseTokenHolder for access-control tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        address untrustedSender = makeAddr("untrustedSender");
        vm.deal(untrustedSender, 1 ether);

        vm.prank(untrustedSender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, untrustedSender));
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: 1 ether}(0);
    }

    /// @notice Verifies that BaseTokenHolder records L1-destined bridging from InteropCenter.
    function test_baseTokenHolder_recordsInteropCenterWithdrawal() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 1 ether;

        // InteropCenter calls burnAndStartBridging (simulating a bridging burn).
        vm.deal(L2_INTEROP_CENTER_ADDR, burnAmount);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(1);

        (uint256 withdrawals, ) = L2_BASE_TOKEN_HOLDER.baseTokenInteropInfo();
        assertEq(withdrawals, burnAmount);
    }

    /// @notice Verifies that BaseTokenHolder does not attribute L2-destined bridging to L1.
    function test_baseTokenHolder_doesNotRecordL2DestinedNtvBridging() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 2 ether;

        // NativeTokenVault calls burnAndStartBridging (simulating a bridging burn)
        vm.deal(L2_NATIVE_TOKEN_VAULT_ADDR, burnAmount);
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(505);

        (uint256 withdrawals, ) = L2_BASE_TOKEN_HOLDER.baseTokenInteropInfo();
        assertEq(withdrawals, 0);
    }

    /// @notice Verifies that L2BaseToken can call burnAndStartBridging for withdrawals
    /// @dev This test ensures L2BaseToken is a valid bridging caller
    function test_baseTokenHolder_recordsL2BaseTokenWithdrawal() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 1 ether;

        // L2BaseToken calls burnAndStartBridging (simulating a withdrawal)
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, burnAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(1);

        (uint256 withdrawals, ) = L2_BASE_TOKEN_HOLDER.baseTokenInteropInfo();
        assertEq(withdrawals, burnAmount);
    }

    /// @notice Verifies that BaseTokenHolder records nothing on initialization receive().
    /// @dev L2BaseToken sends via receive() during initialization, which is not a bridging operation
    function test_baseTokenHolder_doesNotRecordReceiveFromL2BaseToken() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 initAmount = 1 ether;

        // L2BaseToken sends ETH to BaseTokenHolder via receive() (during initialization)
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, initAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: initAmount}("");
        assertTrue(success, "Transfer should succeed");

        (uint256 withdrawals, uint256 deposits) = L2_BASE_TOKEN_HOLDER.baseTokenInteropInfo();
        assertEq(withdrawals, 0);
        assertEq(deposits, 0);
    }

    /// @notice Verifies that initL2 does not record a bridge operation.
    function test_initL2_doesNotRecordBridgeOperation() public {
        // Deploy L2BaseTokenZKOS at the expected system contract address
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());

        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Call initL2
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(1);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            INITIAL_BASE_TOKEN_HOLDER_BALANCE,
            "BaseTokenHolder should have received initial balance"
        );
    }

    /*//////////////////////////////////////////////////////////////
                setZKsyncOSPreV31TotalSupply() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setZkosPreV31TotalSupply_success() public {
        uint256 preV31Supply = 42 ether;
        _initializeBackfill(l2BaseToken, true);

        vm.expectEmit(false, false, false, true);
        emit IL2BaseTokenZKOS.ZKsyncOSPreV31TotalSupplySet(preV31Supply);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(preV31Supply);

        assertEq(l2BaseToken.zkosPreV31TotalSupply(), preV31Supply, "zkosPreV31TotalSupply should be set");
        assertFalse(l2BaseToken.needBaseTokenTotalSupplyBackfill(), "backfill flag should be cleared");
    }

    function test_setZkosPreV31TotalSupply_emitsEvent() public {
        uint256 totalSupply = 42 ether;
        _initializeBackfill(l2BaseToken, true);

        vm.expectEmit(false, false, false, true);
        emit IL2BaseTokenZKOS.ZKsyncOSPreV31TotalSupplySet(totalSupply);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(totalSupply);
    }

    function test_setZkosPreV31TotalSupply_revertIfNotServiceTransactionSender() public {
        address nonServiceSender = makeAddr("nonServiceSender");

        vm.prank(nonServiceSender);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonServiceSender));
        l2BaseToken.setZKsyncOSPreV31TotalSupply(42 ether);
    }

    function test_setZkosPreV31TotalSupply_affectsTotalSupply() public {
        uint256 preV31Supply = 10 ether;

        // Deploy at system address so we can check totalSupply
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);
        _initializeBackfill(L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR), true);

        // Deploy BaseTokenHolder so holder balance is known
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new DummyL2BaseTokenHolder()).code);
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).setZKsyncOSPreV31TotalSupply(preV31Supply);

        // totalSupply = preV31Supply + (INITIAL - holder.balance) = preV31Supply + 0 = preV31Supply
        assertEq(
            L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply(),
            preV31Supply,
            "totalSupply should equal preV31Supply when holder balance equals initial"
        );
    }

    function test_setZkosPreV31TotalSupply_backfillsHolderSnapshot() public {
        uint256 totalSupply = 42 ether;
        L2BaseTokenZKOS tokenAtSystemAddress = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(tokenAtSystemAddress).code);
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);

        vm.startPrank(L2_COMPLEX_UPGRADER_ADDR);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initializeTotalSupplyBackfill(true);
        L2_BASE_TOKEN_HOLDER.initializeBookkeeping(SavedTotalSupply({isSaved: true, amount: 0}), true);
        vm.stopPrank();

        vm.prank(SERVICE_TRANSACTION_SENDER);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).setZKsyncOSPreV31TotalSupply(totalSupply);

        (bool isSaved, uint256 amount) = L2_BASE_TOKEN_HOLDER.baseTokenPreTrackingTotalSupply();
        assertTrue(isSaved);
        assertEq(amount, totalSupply);
        assertFalse(L2_BASE_TOKEN_HOLDER.baseTokenPreTrackingTotalSupplyBackfillPending());
    }

    function test_setZkosPreV31TotalSupply_revertsOnSecondCall() public {
        uint256 totalSupply = 42 ether;
        _initializeBackfill(l2BaseToken, true);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(totalSupply);

        // Second call reverts because the pending flag was cleared.
        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(BaseTokenTotalSupplyBackfillNotNeeded.selector);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(totalSupply);
    }

    function test_setZkosPreV31TotalSupply_revertsWhenBackfillNotNeeded() public {
        _initializeBackfill(l2BaseToken, false);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(BaseTokenTotalSupplyBackfillNotNeeded.selector);
        l2BaseToken.setZKsyncOSPreV31TotalSupply(42 ether);
    }

    function test_initializeTotalSupplyBackfill_setsStateOnce() public {
        _initializeBackfill(l2BaseToken, true);

        assertTrue(l2BaseToken.totalSupplyBackfillStateInitialized());
        assertTrue(l2BaseToken.needBaseTokenTotalSupplyBackfill());

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenBookkeepingAlreadyInitialized.selector);
        l2BaseToken.initializeTotalSupplyBackfill(false);
    }

    function test_initializeTotalSupplyBackfill_revertsUnauthorized() public {
        address nonUpgrader = makeAddr("nonUpgrader");
        vm.prank(nonUpgrader);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonUpgrader));
        l2BaseToken.initializeTotalSupplyBackfill(true);
    }

    /*//////////////////////////////////////////////////////////////
                        totalSupply() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_totalSupply_revertsWhenBackfillNeeded() public {
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        _initializeBackfill(L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR), true);

        vm.expectRevert(BaseTokenPreV31TotalSupplyNotSet.selector);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply();
    }

    function test_totalSupply_worksWhenBackfillNotNeeded() public {
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Deploy BaseTokenHolder so holder balance is known
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, hex"00");
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // Without setting preV31Supply, totalSupply = 0 + (INITIAL - INITIAL) = 0
        assertEq(
            L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply(),
            0,
            "totalSupply should be 0 when preV31Supply is 0 and holder has initial balance"
        );
    }

    function test_totalSupply_worksWhenBaseTokenHolderBalanceGreaterThanInitial() public {
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Deploy BaseTokenHolder so holder balance is known
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new DummyL2BaseTokenHolder()).code);
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE + 100);

        // Set the pre-V31 total supply
        _initializeBackfill(L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR), true);
        vm.prank(SERVICE_TRANSACTION_SENDER);
        L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).setZKsyncOSPreV31TotalSupply(200);

        // totalSupply = preV31Supply + INITIAL - holder.balance = 200 + INITIAL - (INITIAL + 100) = 100
        assertEq(
            L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply(),
            100,
            "totalSupply returns wrong value"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        INTERFACE COMPLIANCE
    //////////////////////////////////////////////////////////////*/

    function test_implementsIL2BaseTokenBase() public view {
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
            IMailboxLegacy.finalizeEthWithdrawal.selector,
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
        assertEq(selector, IMailboxLegacy.finalizeEthWithdrawal.selector, "Selector should match");
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
}

/// @notice Helper contract that rejects ETH transfers via receive()
contract RejectingContract {
    receive() external payable {
        revert("Rejected");
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
