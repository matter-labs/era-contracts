// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {IBaseTokenHolder} from "contracts/l2-system/interfaces/IBaseTokenHolder.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {
    L2_BOOTLOADER_ADDRESS,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    BaseTokenNativeToThisChain,
    L1ChainIdNotSet,
    RecoverToL1NotSupported,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";

/// @title BaseTokenHolderTest
/// @notice Unit tests for BaseTokenHolder contract
/// @dev The NativeTokenVault (the holder's source for `L1_CHAIN_ID` / base-token origin) is not
/// deployed in this isolated unit environment, so its reads are mocked in `setUp`.
contract BaseTokenHolderTest is Test {
    BaseTokenHolder internal baseTokenHolder;

    address internal recipient;
    uint256 internal constant INITIAL_BALANCE = 100 ether;
    uint256 internal constant L1_CHAIN_ID = 9;
    uint256 internal constant ERA_CHAIN_ID = 271;
    uint256 internal constant OTHER_L2_CHAIN_ID = 505;
    bytes32 internal constant BASE_TOKEN_ASSET_ID = keccak256("base_token_asset_id");

    function setUp() public {
        baseTokenHolder = new BaseTokenHolder();
        recipient = makeAddr("recipient");

        // The holder reads the L1 chain id and the base token's origin from the NativeTokenVault;
        // mock them since the vault is out of scope for these unit tests.
        _mockNtvReads(L1_CHAIN_ID, L1_CHAIN_ID);

        // Fund the BaseTokenHolder contract
        vm.deal(address(baseTokenHolder), INITIAL_BALANCE);
    }

    function _mockNtvReads(uint256 _l1ChainId, uint256 _baseTokenOriginChainId) internal {
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.L1_CHAIN_ID.selector),
            abi.encode(_l1ChainId)
        );
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.BASE_TOKEN_ASSET_ID.selector),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeCall(INativeTokenVaultBase.originChainId, (BASE_TOKEN_ASSET_ID)),
            abi.encode(_baseTokenOriginChainId)
        );
    }

    function _readWithdrawals() internal view returns (uint256 withdrawals) {
        (withdrawals, ) = baseTokenHolder.baseTokenInteropInfo();
    }

    function _readDeposits() internal view returns (uint256 deposits) {
        (, deposits) = baseTokenHolder.baseTokenInteropInfo();
    }

    /*//////////////////////////////////////////////////////////////
                            give() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_give_successFromInteropHandler() public {
        uint256 amount = 1 ether;
        uint256 recipientBalanceBefore = recipient.balance;
        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.expectEmit(true, false, false, true, address(baseTokenHolder));
        emit IBaseTokenHolder.BaseTokenMintedInterop(recipient, amount);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, amount, ERA_CHAIN_ID);

        assertEq(recipient.balance, recipientBalanceBefore + amount, "Recipient should receive tokens");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore - amount, "Holder balance should decrease");
    }

    function test_give_zeroAmountDoesNothing() public {
        uint256 recipientBalanceBefore = recipient.balance;
        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, 0, ERA_CHAIN_ID);

        assertEq(recipient.balance, recipientBalanceBefore, "Recipient balance should not change");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore, "Holder balance should not change");
    }

    /// @notice An L1-originated give is recorded in the deposit counter.
    function test_give_fromL1RecordsDeposit() public {
        uint256 amount = 1 ether;
        uint256 depositsBefore = _readDeposits();

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, amount, L1_CHAIN_ID);

        assertEq(_readDeposits() - depositsBefore, amount, "totalSuccessfulDepositsFromL1 should increase");
        assertEq(_readWithdrawals(), 0, "withdrawal counter must not move");
    }

    /// @notice A give originating from another L2 does not touch the L1 deposit counter.
    function test_give_fromOtherL2DoesNotRecordDeposit() public {
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, 1 ether, ERA_CHAIN_ID);

        assertEq(_readDeposits(), 0, "totalSuccessfulDepositsFromL1 must not move for L2->L2 gives");
    }

    /// @notice Recording with a non-zero amount is impossible before the L1 chain id is initialized.
    function test_give_revertWhenL1ChainIdNotSet() public {
        _mockNtvReads(0, L1_CHAIN_ID);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert(L1ChainIdNotSet.selector);
        baseTokenHolder.give(recipient, 1 ether, ERA_CHAIN_ID);
    }

    function test_give_revertWhenRecipientRejectsETH() public {
        uint256 amount = 1 ether;

        // Deploy a contract that rejects ETH
        RejectingETHContract rejecting = new RejectingETHContract();

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert("Address: unable to send value, recipient may have reverted");
        baseTokenHolder.give(address(rejecting), amount, ERA_CHAIN_ID);
    }

    function test_give_revertWhenCalledByNonInteropHandler() public {
        address nonInteropHandler = makeAddr("nonInteropHandler");

        vm.prank(nonInteropHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonInteropHandler));
        baseTokenHolder.give(recipient, 1 ether, ERA_CHAIN_ID);
    }

    function test_give_revertWhenCalledByInteropCenter() public {
        // InteropCenter can call burnAndStartBridging() but cannot call give()
        vm.prank(L2_INTEROP_CENTER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_INTEROP_CENTER_ADDR));
        baseTokenHolder.give(recipient, 1 ether, ERA_CHAIN_ID);
    }

    function test_give_revertWhenCalledByNativeTokenVault() public {
        // NTV can call burnAndStartBridging() but cannot call give()
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_NATIVE_TOKEN_VAULT_ADDR));
        baseTokenHolder.give(recipient, 1 ether, ERA_CHAIN_ID);
    }

    function testFuzz_give_variousAmounts(uint256 amount) public {
        vm.assume(amount > 0 && amount <= INITIAL_BALANCE);

        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, amount, L1_CHAIN_ID);

        assertEq(recipient.balance, recipientBalanceBefore + amount, "Recipient should receive correct amount");
        assertEq(_readDeposits(), amount, "deposit counter should match the given amount");
    }

    /*//////////////////////////////////////////////////////////////
                            receive() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_receive_acceptsFromL2BaseToken() public {
        uint256 amount = 1 ether;
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore + amount, "Holder should receive tokens");
    }

    function test_receive_rejectFromInteropHandler() public {
        // L2InteropHandler should use give() not receive()
        uint256 amount = 1 ether;
        vm.deal(L2_INTEROP_HANDLER_ADDR, amount);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail - L2InteropHandler should use give()");
    }

    function test_receive_rejectFromInteropCenter() public {
        // InteropCenter should use burnAndStartBridging() not receive()
        uint256 amount = 1 ether;
        vm.deal(L2_INTEROP_CENTER_ADDR, amount);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail - InteropCenter should use burnAndStartBridging()");
    }

    function test_receive_rejectFromNativeTokenVault() public {
        // NTV should use burnAndStartBridging() not receive()
        uint256 amount = 1 ether;
        vm.deal(L2_NATIVE_TOKEN_VAULT_ADDR, amount);

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail - NTV should use burnAndStartBridging()");
    }

    function test_receive_revertFromUntrustedSender() public {
        address untrustedSender = makeAddr("untrustedSender");
        uint256 amount = 1 ether;
        vm.deal(untrustedSender, amount);

        vm.prank(untrustedSender);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail from untrusted sender");
    }

    function testFuzz_receive_variousAmountsFromL2BaseToken(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max);

        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertTrue(success, "Transfer should succeed from L2BaseToken");
        assertEq(
            address(baseTokenHolder).balance,
            holderBalanceBefore + amount,
            "Holder should receive correct amount"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    burnAndStartBridging() TESTS
    //////////////////////////////////////////////////////////////*/

    function _burnAndStartBridging_success(address _caller, uint256 _toChainId) internal {
        uint256 amount = 1 ether;
        vm.deal(_caller, amount);

        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.expectEmit(true, false, false, true, address(baseTokenHolder));
        emit IBaseTokenHolder.BaseTokenBurntInterop(_caller, _toChainId, amount);

        vm.prank(_caller);
        baseTokenHolder.burnAndStartBridging{value: amount}(_toChainId);

        assertEq(
            address(baseTokenHolder).balance,
            holderBalanceBefore + amount,
            "Holder should receive the burnt tokens"
        );
    }

    function test_burnAndStartBridging_successFromInteropCenter() public {
        _burnAndStartBridging_success(L2_INTEROP_CENTER_ADDR, ERA_CHAIN_ID);
        assertEq(_readWithdrawals(), 0, "an L2->L2 burn must not count as an L1 withdrawal");
    }

    function test_burnAndStartBridging_successFromNativeTokenVault() public {
        _burnAndStartBridging_success(L2_NATIVE_TOKEN_VAULT_ADDR, ERA_CHAIN_ID);
        assertEq(_readWithdrawals(), 0, "an L2->L2 burn must not count as an L1 withdrawal");
    }

    /// @notice An L1-destined burn is recorded in the withdrawal counter.
    function test_burnAndStartBridging_toL1RecordsWithdrawal() public {
        uint256 amount = 2 ether;
        vm.deal(L2_INTEROP_CENTER_ADDR, amount);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        baseTokenHolder.burnAndStartBridging{value: amount}(L1_CHAIN_ID);

        assertEq(_readWithdrawals(), amount, "totalWithdrawalsToL1 should increase for an L1-destined burn");
        assertEq(_readDeposits(), 0, "deposit counter must not move");
    }

    /// @notice Recording with a non-zero value is impossible before the L1 chain id is initialized.
    function test_burnAndStartBridging_revertWhenL1ChainIdNotSet() public {
        _mockNtvReads(0, L1_CHAIN_ID);
        vm.deal(L2_INTEROP_CENTER_ADDR, 1 ether);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        vm.expectRevert(L1ChainIdNotSet.selector);
        baseTokenHolder.burnAndStartBridging{value: 1 ether}(ERA_CHAIN_ID);
    }

    /// @dev L2BaseToken is no longer a bridging caller: base-token withdrawals go through the InteropCenter,
    /// which is the contract that burns the value via `burnAndStartBridging`.
    function test_burnAndStartBridging_revertFromL2BaseToken() public {
        vm.deal(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, 1 ether);

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR));
        baseTokenHolder.burnAndStartBridging{value: 1 ether}(ERA_CHAIN_ID);
    }

    function test_burnAndStartBridging_revertFromUnauthorizedCaller() public {
        address unauthorizedCaller = makeAddr("unauthorizedCaller");
        uint256 amount = 1 ether;

        vm.deal(unauthorizedCaller, amount);

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, unauthorizedCaller));
        baseTokenHolder.burnAndStartBridging{value: amount}(ERA_CHAIN_ID);
    }

    function test_burnAndStartBridging_revertFromInteropHandler() public {
        vm.deal(L2_INTEROP_HANDLER_ADDR, 1 ether);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_INTEROP_HANDLER_ADDR));
        baseTokenHolder.burnAndStartBridging{value: 1 ether}(ERA_CHAIN_ID);
    }

    function test_burnAndStartBridging_revertFromComplexUpgrader() public {
        vm.deal(L2_COMPLEX_UPGRADER_ADDR, 1 ether);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_COMPLEX_UPGRADER_ADDR));
        baseTokenHolder.burnAndStartBridging{value: 1 ether}(ERA_CHAIN_ID);
    }

    function test_burnAndStartBridging_revertFromBootloader() public {
        vm.deal(L2_BOOTLOADER_ADDRESS, 1 ether);

        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_BOOTLOADER_ADDRESS));
        baseTokenHolder.burnAndStartBridging{value: 1 ether}(ERA_CHAIN_ID);
    }

    /*//////////////////////////////////////////////////////////////
                    recordBaseTokenDeposit() TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The Era bootloader mint path: L2BaseToken records the inbound deposit here.
    function test_recordBaseTokenDeposit_fromL1RecordsDeposit() public {
        uint256 amount = 4 ether;

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        baseTokenHolder.recordBaseTokenDeposit(L1_CHAIN_ID, amount);

        assertEq(_readDeposits(), amount, "totalSuccessfulDepositsFromL1 should increase");
    }

    function test_recordBaseTokenDeposit_zeroAmountIsNoop() public {
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        baseTokenHolder.recordBaseTokenDeposit(L1_CHAIN_ID, 0);

        assertEq(_readDeposits(), 0, "zero amounts are not recorded");
    }

    function test_recordBaseTokenDeposit_fromOtherL2DoesNotRecordDeposit() public {
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        baseTokenHolder.recordBaseTokenDeposit(ERA_CHAIN_ID, 1 ether);

        assertEq(_readDeposits(), 0, "non-L1 sources are not recorded");
    }

    function test_recordBaseTokenDeposit_revertUnauthorized() public {
        address unauthorizedCaller = makeAddr("unauthorizedCaller");

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, unauthorizedCaller));
        baseTokenHolder.recordBaseTokenDeposit(L1_CHAIN_ID, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    ORDERING INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that the deposit is recorded BEFORE the ETH transfer: a recipient's receive
    /// hook must already observe the updated counter, so the bookkeeping cannot be manipulated by
    /// re-entering during the transfer.
    function test_give_recordsBeforeTransfer() public {
        uint256 amount = 1 ether;
        CounterObservingRecipient observer = new CounterObservingRecipient(baseTokenHolder);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(address(observer), amount, L1_CHAIN_ID);

        assertEq(
            observer.observedDeposits(),
            amount,
            "the deposit counter must already be updated when the ETH transfer executes"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        INTERFACE COMPLIANCE
    //////////////////////////////////////////////////////////////*/

    function test_implementsIBaseTokenHolder() public {
        IBaseTokenHolder holder = IBaseTokenHolder(address(baseTokenHolder));

        // Verify give() is callable (zero amount returns early, no mocks needed)
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        holder.give(recipient, 0, ERA_CHAIN_ID);

        // Verify burnAndStartBridging() is callable
        vm.deal(L2_INTEROP_CENTER_ADDR, 1);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        holder.burnAndStartBridging{value: 1}(ERA_CHAIN_ID);

        // Verify the counters are readable through the interface
        (uint256 withdrawals, uint256 deposits) = holder.baseTokenInteropInfo();
        (withdrawals, deposits);
    }

    /*//////////////////////////////////////////////////////////////
                        recoverBaseToken() TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Regression tests for base-token bridge-out recovery: a failed/timed-out base-token bridge-out is
    /// refunded via recoverBaseToken, which returns the escrowed value to the depositor. The forward direction
    /// records nothing for an L2->L2 bridge-out of the never-native base token, so there is no accounting to
    /// reverse. Without this path the escrowed base token would be permanently stranded on an atomic timeout.
    function test_recoverBaseToken_successFromNativeTokenVault() public {
        uint256 amount = 3 ether;
        uint256 recipientBalanceBefore = recipient.balance;
        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.expectEmit(true, false, false, true, address(baseTokenHolder));
        emit IBaseTokenHolder.BaseTokenRecovered(recipient, amount);

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        baseTokenHolder.recoverBaseToken(recipient, amount, OTHER_L2_CHAIN_ID);

        assertEq(recipient.balance, recipientBalanceBefore + amount, "recipient must receive the recovered value");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore - amount, "holder balance must decrease");
        (uint256 withdrawals, uint256 deposits) = baseTokenHolder.baseTokenInteropInfo();
        assertEq(withdrawals, 0, "no withdrawal accounting may move on recovery");
        assertEq(deposits, 0, "no deposit accounting may move on recovery");
    }

    /// @notice Recovering an L1-destined bridge-out is unreachable (the InteropCenter rejects L1-destined
    /// atomic bundles at send) and must revert: `totalWithdrawalsToL1` must stay append-only.
    function test_recoverBaseToken_revertWhenToL1() public {
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(RecoverToL1NotSupported.selector);
        baseTokenHolder.recoverBaseToken(recipient, 1 ether, L1_CHAIN_ID);
    }

    /// @notice The base token can never originate from this chain; the recovery asserts the invariant
    /// instead of silently skipping accounting that was never recorded.
    function test_recoverBaseToken_revertWhenBaseTokenNativeToThisChain() public {
        _mockNtvReads(L1_CHAIN_ID, block.chainid);

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(BaseTokenNativeToThisChain.selector);
        baseTokenHolder.recoverBaseToken(recipient, 1 ether, OTHER_L2_CHAIN_ID);
    }

    function test_recoverBaseToken_zeroAmountIsNoop() public {
        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        baseTokenHolder.recoverBaseToken(recipient, 0, OTHER_L2_CHAIN_ID);

        assertEq(recipient.balance, 0);
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore);
    }

    /// @dev Recovery is NativeTokenVault-only — tighter than burnAndStartBridging (which also allows the
    /// InteropCenter). Neither the InteropCenter nor the InteropHandler may trigger a base-token recovery.
    function test_recoverBaseToken_revertFromInteropCenter() public {
        vm.prank(L2_INTEROP_CENTER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_INTEROP_CENTER_ADDR));
        baseTokenHolder.recoverBaseToken(recipient, 1 ether, OTHER_L2_CHAIN_ID);
    }

    function test_recoverBaseToken_revertFromInteropHandler() public {
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_INTEROP_HANDLER_ADDR));
        baseTokenHolder.recoverBaseToken(recipient, 1 ether, OTHER_L2_CHAIN_ID);
    }
}

/// @notice Helper contract that rejects ETH transfers via receive()
contract RejectingETHContract {
    receive() external payable {
        revert("Rejected");
    }
}

/// @notice Helper recipient that snapshots the holder's deposit counter inside its receive hook.
contract CounterObservingRecipient {
    BaseTokenHolder public immutable HOLDER;
    uint256 public observedDeposits;

    constructor(BaseTokenHolder _holder) {
        HOLDER = _holder;
    }

    receive() external payable {
        (, observedDeposits) = HOLDER.baseTokenInteropInfo();
    }
}
