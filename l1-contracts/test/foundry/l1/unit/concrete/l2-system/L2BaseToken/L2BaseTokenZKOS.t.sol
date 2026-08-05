// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2BaseTokenZKOS} from "contracts/l2-system/zksync-os/L2BaseTokenZKOS.sol";
import {IL2BaseTokenBase} from "contracts/l2-system/interfaces/IL2BaseTokenBase.sol";
import {IL2ToL1Messenger} from "contracts/common/l2-helpers/IL2ToL1Messenger.sol";
import {
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    MINT_BASE_TOKEN_HOOK
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_BASE_TOKEN_HOLDER} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "contracts/common/Config.sol";
import {IMailboxLegacy} from "contracts/state-transition/chain-interfaces/IMailboxLegacy.sol";
import {
    BaseTokenHolderAlreadyInitialized,
    BaseTokenHolderMintFailed,
    InvalidCaller,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {DummyL2L1Messenger} from "contracts/dev-contracts/test/DummyL2L1Messenger.sol";
import {DummyL2BaseTokenHolder} from "contracts/dev-contracts/test/DummyL2BaseTokenHolder.sol";

/// @dev Records the base-token flows the real BaseTokenHolder reports. The settlement-layer
/// gating of these flows lives in the real L2NativeTokenVault and is covered by its own tests.
contract MockRecordingVault {
    uint256 public recordedToChainId;
    uint256 public recordedToAmount;
    uint256 public toChainCalls;

    function recordBaseTokenBridgingToChain(uint256 _toChainId, uint256 _amount) external {
        if (msg.sender != L2_BASE_TOKEN_HOLDER_ADDR) {
            revert InvalidCaller(msg.sender);
        }
        recordedToChainId = _toChainId;
        recordedToAmount = _amount;
        toChainCalls++;
    }

    function recordBaseTokenBridgingFromChain(uint256, uint256) external {
        if (msg.sender != L2_BASE_TOKEN_HOLDER_ADDR) {
            revert InvalidCaller(msg.sender);
        }
    }
}

/// @dev Harness exposing a setter for the slot that draft-v31's backfill service transaction
/// (removed in this release) used to write, so an upgraded chain's pre-populated state can be
/// simulated without storage cheatcodes.
contract L2BaseTokenZKOSHarness is L2BaseTokenZKOS {
    function harnessSetZkosPreV31TotalSupply(uint256 _totalSupply) external {
        zkosPreV31TotalSupply = _totalSupply;
    }
}

/// @title L2BaseTokenZKOSTest
/// @notice Unit tests for L2BaseTokenZKOS (init, totalSupply).
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

        // The real BaseTokenHolder reports bridge flows to the vault; a recording mock stands in.
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, address(new MockRecordingVault()).code);
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

    /// @dev Covers the holder->vault forwarding only: the vault is a recording mock, so the real
    /// vault's settlement gating / `interopInfo` update is exercised in L2AssetBookkeeping.t.sol.
    function test_withdraw_forwardsBaseTokenBookkeepingToVault() public {
        // Use the actual holder to verify the forwarded withdrawal.
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

        MockRecordingVault vault = MockRecordingVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        assertEq(vault.toChainCalls(), 1, "withdrawal should be reported to the vault");
        assertEq(vault.recordedToChainId(), 1, "withdrawal destination should be the L1 chain id");
        assertEq(vault.recordedToAmount(), WITHDRAW_AMOUNT, "withdrawal amount should be forwarded verbatim");
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

    /// @dev Forwarding-only coverage, like `test_withdraw_forwardsBaseTokenBookkeepingToVault`.
    function test_withdrawWithMessage_forwardsBaseTokenBookkeepingToVault() public {
        // Use the actual holder to verify the forwarded withdrawal.
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

        MockRecordingVault vault = MockRecordingVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        assertEq(vault.toChainCalls(), 1, "withdrawal should be reported to the vault");
        assertEq(vault.recordedToChainId(), 1, "withdrawal destination should be the L1 chain id");
        assertEq(vault.recordedToAmount(), WITHDRAW_AMOUNT, "withdrawal amount should be forwarded verbatim");
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

    /// @notice Verifies that BaseTokenHolder reports InteropCenter bridging burns to the vault.
    function test_baseTokenHolder_reportsInteropCenterBurnToVault() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 1 ether;

        // InteropCenter calls burnAndStartBridging (simulating a bridging burn).
        vm.deal(L2_INTEROP_CENTER_ADDR, burnAmount);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(1);

        MockRecordingVault vault = MockRecordingVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        assertEq(vault.toChainCalls(), 1);
        assertEq(vault.recordedToChainId(), 1);
        assertEq(vault.recordedToAmount(), burnAmount);
    }

    /// @notice Verifies that L2BaseToken can call burnAndStartBridging for withdrawals
    /// @dev This test ensures L2BaseToken is a valid bridging caller
    function test_baseTokenHolder_reportsL2BaseTokenWithdrawalToVault() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 burnAmount = 1 ether;

        // L2BaseToken calls burnAndStartBridging (simulating a withdrawal)
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, burnAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: burnAmount}(1);

        MockRecordingVault vault = MockRecordingVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        assertEq(vault.toChainCalls(), 1);
        assertEq(vault.recordedToAmount(), burnAmount);
    }

    /// @notice Verifies that BaseTokenHolder reports nothing on initialization receive().
    /// @dev L2BaseToken sends via receive() during initialization, which is not a bridging operation
    function test_baseTokenHolder_doesNotReportReceiveFromL2BaseToken() public {
        // Deploy real BaseTokenHolder for integration tests
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new BaseTokenHolder()).code);
        uint256 initAmount = 1 ether;

        // L2BaseToken sends ETH to BaseTokenHolder via receive() (during initialization)
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, initAmount);
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: initAmount}("");
        assertTrue(success, "Transfer should succeed");

        MockRecordingVault vault = MockRecordingVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        assertEq(vault.toChainCalls(), 0, "initialization receive must not be reported as a bridge flow");
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
                        totalSupply() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_totalSupply_zeroForFreshChain() public {
        L2BaseTokenZKOS l2BaseTokenAtSystemAddr = new L2BaseTokenZKOS();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(l2BaseTokenAtSystemAddr).code);

        // Deploy BaseTokenHolder so holder balance is known
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, hex"00");
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // On a fresh chain zkosPreV31TotalSupply is zero: totalSupply = 0 + (INITIAL - INITIAL) = 0
        assertEq(
            L2BaseTokenZKOS(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).totalSupply(),
            0,
            "totalSupply should be 0 when preV31Supply is 0 and holder has initial balance"
        );
    }

    /// @dev Simulates an upgraded chain whose `zkosPreV31TotalSupply` slot was backfilled while it
    /// ran draft-v31, plus post-upgrade mints (a holder balance below the initial value means
    /// minted supply).
    function test_totalSupply_addsPreV31SupplyToMintedDelta() public {
        L2BaseTokenZKOSHarness harness = new L2BaseTokenZKOSHarness();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(harness).code);
        L2BaseTokenZKOSHarness token = L2BaseTokenZKOSHarness(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        token.harnessSetZkosPreV31TotalSupply(200);

        // 100 wei were minted after the upgrade: the holder balance is below the initial value.
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new DummyL2BaseTokenHolder()).code);
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE - 100);

        // totalSupply = preV31Supply + INITIAL - holder.balance = 200 + 100 = 300
        assertEq(token.totalSupply(), 300, "totalSupply returns wrong value");
    }

    /// @dev An upgraded chain can be in a net-burn state: withdrawals move value INTO the holder,
    /// so its balance can exceed the initial value by up to the pre-v31 circulating supply.
    /// totalSupply() must not revert there. The burn goes through a real withdrawal.
    function test_totalSupply_supportsNetBurnOfPreV31Supply() public {
        L2BaseTokenZKOSHarness harness = new L2BaseTokenZKOSHarness();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(harness).code);
        L2BaseTokenZKOSHarness token = L2BaseTokenZKOSHarness(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        token.harnessSetZkosPreV31TotalSupply(200);

        // Post-upgrade steady state: the holder holds exactly the initial balance.
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, address(new DummyL2BaseTokenHolder()).code);
        vm.deal(L2_BASE_TOKEN_HOLDER_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);

        // A holder of pre-v31 supply withdraws 150 wei to L1: the value flows into the holder.
        address preV31Holder = makeAddr("preV31Holder");
        vm.deal(preV31Holder, 150);
        vm.prank(preV31Holder);
        token.withdraw{value: 150}(l1Receiver);

        assertEq(
            L2_BASE_TOKEN_HOLDER_ADDR.balance,
            INITIAL_BASE_TOKEN_HOLDER_BALANCE + 150,
            "the withdrawal must flow into the holder"
        );
        // totalSupply = preV31Supply + INITIAL - holder.balance = 200 - 150 = 50
        assertEq(token.totalSupply(), 50, "net-burn state should decrease totalSupply without reverting");
    }

    /// @dev Simulates a draft-v31 chain (slot 50 already backfilled) going through this release's
    /// initL2: the historical value must survive and feed totalSupply().
    function test_initL2_preservesBackfilledPreV31Supply() public {
        L2BaseTokenZKOSHarness harness = new L2BaseTokenZKOSHarness();
        vm.etch(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(harness).code);
        L2BaseTokenZKOSHarness token = L2BaseTokenZKOSHarness(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        token.harnessSetZkosPreV31TotalSupply(200);

        vm.mockCall(MINT_BASE_TOKEN_HOOK, abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE), abi.encode());
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, INITIAL_BASE_TOKEN_HOLDER_BALANCE);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        token.initL2(1);

        assertEq(token.zkosPreV31TotalSupply(), 200, "initL2 must not touch the backfilled slot");
        // Holder now holds exactly the initial balance, so totalSupply() equals the pre-v31 value.
        assertEq(token.totalSupply(), 200, "totalSupply must keep the pre-v31 baseline after initL2");
    }

    /// @dev Pins `zkosPreV31TotalSupply` to storage slot 50: the value is written by draft-v31's
    /// backfill service transaction, and this release (which removes the backfill path) must keep
    /// reading the exact same slot. The write goes through a derived-contract setter, the read
    /// through the raw slot.
    function test_zkosPreV31TotalSupply_stableStorageSlot() public {
        L2BaseTokenZKOSHarness harness = new L2BaseTokenZKOSHarness();
        harness.harnessSetZkosPreV31TotalSupply(31337);

        assertEq(
            uint256(vm.load(address(harness), bytes32(uint256(50)))),
            31337,
            "zkosPreV31TotalSupply must stay at slot 50 (populated on draft-v31)"
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
