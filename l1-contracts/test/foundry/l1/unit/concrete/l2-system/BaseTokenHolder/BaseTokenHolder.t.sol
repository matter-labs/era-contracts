// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {IBaseTokenHolder} from "contracts/l2-system/interfaces/IBaseTokenHolder.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {SavedTotalSupply} from "contracts/common/L2AssetBookkeeping.sol";
import {ISystemContext} from "contracts/common/interfaces/ISystemContext.sol";
import {
    L2_BOOTLOADER_ADDRESS,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    BaseTokenBookkeepingAlreadyInitialized,
    BaseTokenBookkeepingNotInitialized,
    BaseTokenTotalSupplyBackfillNotNeeded,
    L1ChainIdNotSet,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";

/// @title BaseTokenHolderTest
/// @notice Unit tests for BaseTokenHolder contract
contract BaseTokenHolderTest is Test {
    BaseTokenHolder internal baseTokenHolder;

    address internal recipient;
    uint256 internal constant INITIAL_BALANCE = 100 ether;
    uint256 internal constant L1_CHAIN_ID = 9;
    uint256 internal constant ERA_CHAIN_ID = 271;
    uint256 internal constant GATEWAY_CHAIN_ID = 505;

    function setUp() public {
        baseTokenHolder = new BaseTokenHolder();
        recipient = makeAddr("recipient");

        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.L1_CHAIN_ID.selector),
            abi.encode(L1_CHAIN_ID)
        );
        vm.mockCall(
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(ISystemContext.currentSettlementLayerChainId.selector),
            abi.encode(L1_CHAIN_ID)
        );

        // Fund the BaseTokenHolder contract
        vm.deal(address(baseTokenHolder), INITIAL_BALANCE);
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

    function test_give_fromL1_recordsSuccessfulDeposit() public {
        uint256 amount = 1 ether;

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, amount, L1_CHAIN_ID);

        (, uint256 deposits) = baseTokenHolder.baseTokenInteropInfo();
        assertEq(deposits, amount, "L1 deposit should be recorded");
    }

    function test_give_fromL1WhileSettlingOnGateway_doesNotRecordDeposit() public {
        vm.mockCall(
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(ISystemContext.currentSettlementLayerChainId.selector),
            abi.encode(GATEWAY_CHAIN_ID)
        );

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, 1 ether, L1_CHAIN_ID);

        (, uint256 deposits) = baseTokenHolder.baseTokenInteropInfo();
        assertEq(deposits, 0, "gateway-settled deposit must not be attributed to L1");
    }

    function test_give_revertWhenRecipientRejectsETH() public {
        uint256 amount = 1 ether;

        // Deploy a contract that rejects ETH
        RejectingETHContract rejecting = new RejectingETHContract();

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert("Address: unable to send value, recipient may have reverted");
        baseTokenHolder.give(address(rejecting), amount, L1_CHAIN_ID);

        (, uint256 deposits) = baseTokenHolder.baseTokenInteropInfo();
        assertEq(deposits, 0, "reverted transfer must revert bookkeeping");
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
        baseTokenHolder.give(recipient, amount, ERA_CHAIN_ID);

        assertEq(recipient.balance, recipientBalanceBefore + amount, "Recipient should receive correct amount");
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
        // InteropHandler should use give() not receive()
        uint256 amount = 1 ether;
        vm.deal(L2_INTEROP_HANDLER_ADDR, amount);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        (bool success, ) = address(baseTokenHolder).call{value: amount}("");

        assertFalse(success, "Transfer should fail - InteropHandler should use give()");
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
    }

    function test_burnAndStartBridging_successFromNativeTokenVault() public {
        _burnAndStartBridging_success(L2_NATIVE_TOKEN_VAULT_ADDR, ERA_CHAIN_ID);
    }

    function test_burnAndStartBridging_successFromL2BaseToken() public {
        _burnAndStartBridging_success(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, ERA_CHAIN_ID);
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

    function test_burnAndStartBridging_toL1_recordsWithdrawal() public {
        uint256 amount = 2 ether;

        vm.deal(L2_INTEROP_CENTER_ADDR, amount);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        baseTokenHolder.burnAndStartBridging{value: amount}(L1_CHAIN_ID);

        (uint256 withdrawals, ) = baseTokenHolder.baseTokenInteropInfo();
        assertEq(withdrawals, amount, "L1 withdrawal should be recorded");
    }

    function test_burnAndStartBridging_toL1WhileSettlingOnGateway_doesNotRecordWithdrawal() public {
        vm.mockCall(
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(ISystemContext.currentSettlementLayerChainId.selector),
            abi.encode(GATEWAY_CHAIN_ID)
        );
        uint256 amount = 2 ether;
        vm.deal(L2_INTEROP_CENTER_ADDR, amount);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        baseTokenHolder.burnAndStartBridging{value: amount}(L1_CHAIN_ID);

        (uint256 withdrawals, ) = baseTokenHolder.baseTokenInteropInfo();
        assertEq(withdrawals, 0, "gateway-settled withdrawal must not be attributed to L1");
    }

    /*//////////////////////////////////////////////////////////////
                    ORDERING INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that inbound bookkeeping is updated before control reaches the recipient.
    function test_give_recordsDepositBeforeTransfer() public {
        uint256 amount = 1 ether;
        BookkeepingObservingRecipient observer = new BookkeepingObservingRecipient(baseTokenHolder);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(address(observer), amount, L1_CHAIN_ID);

        assertEq(observer.observedDeposits(), amount, "recipient should observe the completed bookkeeping");
        assertEq(address(observer).balance, amount, "recipient should receive ETH after bookkeeping");
    }

    /*//////////////////////////////////////////////////////////////
                        BOOKKEEPING INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initializeBookkeeping_setsSnapshotOnce() public {
        SavedTotalSupply memory snapshot = SavedTotalSupply({isSaved: true, amount: 123});

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        baseTokenHolder.initializeBookkeeping(snapshot, false);

        (bool isSaved, uint256 amount) = baseTokenHolder.baseTokenPreTrackingTotalSupply();
        assertTrue(isSaved);
        assertEq(amount, 123);
        assertTrue(baseTokenHolder.bookkeepingInitialized());

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenBookkeepingAlreadyInitialized.selector);
        baseTokenHolder.initializeBookkeeping(snapshot, false);
    }

    function test_initializeBookkeeping_revertsUnsavedSnapshot() public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(BaseTokenBookkeepingNotInitialized.selector);
        baseTokenHolder.initializeBookkeeping(SavedTotalSupply({isSaved: false, amount: 0}), false);
    }

    function test_initializeBookkeeping_revertsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        baseTokenHolder.initializeBookkeeping(SavedTotalSupply({isSaved: true, amount: 0}), false);
    }

    function test_backfillBaseTokenPreTrackingTotalSupply() public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        baseTokenHolder.initializeBookkeeping(SavedTotalSupply({isSaved: true, amount: 0}), true);

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        baseTokenHolder.backfillBaseTokenPreTrackingTotalSupply(456);

        (, uint256 amount) = baseTokenHolder.baseTokenPreTrackingTotalSupply();
        assertEq(amount, 456);

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        vm.expectRevert(BaseTokenTotalSupplyBackfillNotNeeded.selector);
        baseTokenHolder.backfillBaseTokenPreTrackingTotalSupply(789);
    }

    function test_backfillBaseTokenPreTrackingTotalSupply_revertsBeforeInitialization() public {
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        vm.expectRevert(BaseTokenBookkeepingNotInitialized.selector);
        baseTokenHolder.backfillBaseTokenPreTrackingTotalSupply(1);
    }

    function test_recordBaseTokenDeposit_onlyL2BaseToken() public {
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        baseTokenHolder.recordBaseTokenDeposit(L1_CHAIN_ID, 17);

        (, uint256 deposits) = baseTokenHolder.baseTokenInteropInfo();
        assertEq(deposits, 17);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        baseTokenHolder.recordBaseTokenDeposit(L1_CHAIN_ID, 1);
    }

    function test_recordBaseTokenDeposit_revertWhenL1ChainIdNotSet() public {
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.L1_CHAIN_ID.selector),
            abi.encode(uint256(0))
        );

        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        vm.expectRevert(L1ChainIdNotSet.selector);
        baseTokenHolder.recordBaseTokenDeposit(ERA_CHAIN_ID, 1 ether);
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
    }
}

/// @notice Helper contract that rejects ETH transfers via receive()
contract RejectingETHContract {
    receive() external payable {
        revert("Rejected");
    }
}

contract BookkeepingObservingRecipient {
    BaseTokenHolder internal immutable holder;
    uint256 public observedDeposits;

    constructor(BaseTokenHolder _holder) {
        holder = _holder;
    }

    receive() external payable {
        (, observedDeposits) = holder.baseTokenInteropInfo();
    }
}
