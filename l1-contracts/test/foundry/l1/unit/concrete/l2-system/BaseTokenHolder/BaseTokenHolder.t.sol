// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {IBaseTokenHolder} from "contracts/l2-system/interfaces/IBaseTokenHolder.sol";
import {
    L2_ASSET_TRACKER_ADDR,
    L2_BOOTLOADER_ADDRESS,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {BaseTokenNativeToThisChain, RecoverToL1NotSupported, Unauthorized} from "contracts/common/L1ContractErrors.sol";

/// @dev Mock L2AssetTracker that records the base-token bridge flows the holder reports.
/// The settlement-layer gating of these flows lives in the real tracker and is covered by the
/// L2AssetTracker tests; here we only verify what the holder forwards.
contract MockRecordingAssetTracker {
    uint256 internal constant MOCK_L1_CHAIN_ID = 9;
    bytes32 internal constant MOCK_BASE_TOKEN_ASSET_ID = bytes32(uint256(0xba5e));

    uint256 public recordedToChainId;
    uint256 public recordedToAmount;
    uint256 public toChainCalls;

    uint256 public recordedFromChainId;
    uint256 public recordedFromAmount;
    uint256 public fromChainCalls;

    uint256 internal baseTokenOriginChainId = MOCK_L1_CHAIN_ID;

    function handleInitiateBaseTokenBridgingOnL2(uint256 _toChainId, uint256 _amount) external {
        if (msg.sender != _holder()) {
            revert Unauthorized(msg.sender);
        }
        recordedToChainId = _toChainId;
        recordedToAmount = _amount;
        toChainCalls++;
    }

    function handleFinalizeBaseTokenBridgingOnL2(uint256 _fromChainId, uint256 _amount) external {
        if (msg.sender != _holder()) {
            revert Unauthorized(msg.sender);
        }
        recordedFromChainId = _fromChainId;
        recordedFromAmount = _amount;
        fromChainCalls++;
    }

    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() external pure returns (uint256) {
        return MOCK_L1_CHAIN_ID;
    }

    // solhint-disable-next-line func-name-mixedcase
    function BASE_TOKEN_ASSET_ID() external pure returns (bytes32) {
        return MOCK_BASE_TOKEN_ASSET_ID;
    }

    function originChainId(bytes32) external view returns (uint256) {
        return baseTokenOriginChainId;
    }

    /// @dev Mirrors `L2AssetTracker.assertBaseTokenRecoveryIsAccountingNeutral` so the holder's
    /// delegation to the tracker stays observable with the recording mock in place.
    function assertBaseTokenRecoveryIsAccountingNeutral(uint256 _toChainId) external view {
        if (_toChainId == MOCK_L1_CHAIN_ID) {
            revert RecoverToL1NotSupported();
        }
        if (baseTokenOriginChainId == block.chainid) {
            revert BaseTokenNativeToThisChain();
        }
    }

    function setBaseTokenOriginChainId(uint256 _originChainId) external {
        baseTokenOriginChainId = _originChainId;
    }

    /// @dev The holder under test is stored by the test contract right after deployment.
    address internal holderAddress;

    function setHolder(address _holderAddress) external {
        holderAddress = _holderAddress;
    }

    function _holder() internal view returns (address) {
        return holderAddress;
    }
}

/// @title BaseTokenHolderTest
/// @notice Unit tests for BaseTokenHolder contract
contract BaseTokenHolderTest is Test {
    BaseTokenHolder internal baseTokenHolder;
    MockRecordingAssetTracker internal tracker;

    address internal recipient;
    uint256 internal constant INITIAL_BALANCE = 100 ether;
    uint256 internal constant L1_CHAIN_ID = 9;
    uint256 internal constant ERA_CHAIN_ID = 271;
    uint256 internal constant GATEWAY_CHAIN_ID = 505;

    function setUp() public {
        baseTokenHolder = new BaseTokenHolder();
        recipient = makeAddr("recipient");

        // The holder reports every bridge flow to the tracker; a recording mock stands in for it.
        MockRecordingAssetTracker trackerImpl = new MockRecordingAssetTracker();
        vm.etch(L2_ASSET_TRACKER_ADDR, address(trackerImpl).code);
        tracker = MockRecordingAssetTracker(L2_ASSET_TRACKER_ADDR);
        tracker.setHolder(address(baseTokenHolder));

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
        assertEq(tracker.fromChainCalls(), 0, "zero-amount give must not be reported to the tracker");
    }

    function test_give_reportsInboundFlowToTracker() public {
        uint256 amount = 1 ether;

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, amount, L1_CHAIN_ID);

        assertEq(tracker.fromChainCalls(), 1, "inbound flow should be reported exactly once");
        assertEq(tracker.recordedFromChainId(), L1_CHAIN_ID, "source chain id should be forwarded verbatim");
        assertEq(tracker.recordedFromAmount(), amount, "amount should be forwarded verbatim");
    }

    function test_give_revertWhenRecipientRejectsETH() public {
        uint256 amount = 1 ether;

        // Deploy a contract that rejects ETH
        RejectingETHContract rejecting = new RejectingETHContract();

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert("Address: unable to send value, recipient may have reverted");
        baseTokenHolder.give(address(rejecting), amount, L1_CHAIN_ID);

        assertEq(tracker.fromChainCalls(), 0, "reverted transfer must revert bookkeeping");
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
    }

    function test_burnAndStartBridging_successFromNativeTokenVault() public {
        _burnAndStartBridging_success(L2_NATIVE_TOKEN_VAULT_ADDR, ERA_CHAIN_ID);
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

    function test_burnAndStartBridging_reportsOutboundFlowToTracker() public {
        uint256 amount = 2 ether;

        vm.deal(L2_INTEROP_CENTER_ADDR, amount);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        baseTokenHolder.burnAndStartBridging{value: amount}(L1_CHAIN_ID);

        assertEq(tracker.toChainCalls(), 1, "outbound flow should be reported exactly once");
        assertEq(tracker.recordedToChainId(), L1_CHAIN_ID, "destination chain id should be forwarded verbatim");
        assertEq(tracker.recordedToAmount(), amount, "amount should be forwarded verbatim");
    }

    /// @dev A zero-value burn is still reported: the tracker's lazy registration is a side effect of
    /// the report, so skipping it would defer registration to the first non-zero flow.
    function test_burnAndStartBridging_zeroValueIsStillReported() public {
        vm.prank(L2_INTEROP_CENTER_ADDR);
        baseTokenHolder.burnAndStartBridging{value: 0}(L1_CHAIN_ID);

        assertEq(tracker.toChainCalls(), 1, "the outbound report happens regardless of the amount");
        assertEq(tracker.recordedToAmount(), 0, "the reported amount is the burnt value");
    }

    /*//////////////////////////////////////////////////////////////
                    ORDERING INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that inbound bookkeeping is updated before control reaches the recipient.
    function test_give_recordsDepositBeforeTransfer() public {
        uint256 amount = 1 ether;
        BookkeepingObservingRecipient observer = new BookkeepingObservingRecipient(tracker);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(address(observer), amount, L1_CHAIN_ID);

        assertEq(observer.observedDeposits(), amount, "recipient should observe the completed bookkeeping");
        assertEq(address(observer).balance, amount, "recipient should receive ETH after bookkeeping");
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

    /*//////////////////////////////////////////////////////////////
                        recoverBaseToken() TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Covers base-token bridge-out recovery via `recoverBaseToken`.
    /// See {protocol-docs/bridging.md#base-token-handling}.
    function test_recoverBaseToken_successFromNativeTokenVault() public {
        uint256 amount = 3 ether;
        uint256 recipientBalanceBefore = recipient.balance;
        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.expectEmit(true, false, false, true, address(baseTokenHolder));
        emit IBaseTokenHolder.BaseTokenRecovered(recipient, amount);

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        baseTokenHolder.recoverBaseToken(recipient, amount, GATEWAY_CHAIN_ID);

        assertEq(recipient.balance, recipientBalanceBefore + amount, "recipient must receive the recovered value");
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore - amount, "holder balance must decrease");
    }

    /// @dev Recovery is only accounting-neutral for L2->L2 bridge-outs: `totalWithdrawalsToL1` is
    /// append-only, so an L1-destined recovery must be rejected outright.
    function test_recoverBaseToken_revertsForL1Destination() public {
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(RecoverToL1NotSupported.selector);
        baseTokenHolder.recoverBaseToken(recipient, 1 ether, L1_CHAIN_ID);
    }

    /// @dev The base token never originates from this chain, so `NativeTokenVaultBase.bridgedOut`
    /// holds nothing to re-credit; a chain-native base token would invalidate that assumption.
    function test_recoverBaseToken_revertsWhenBaseTokenIsNativeToThisChain() public {
        tracker.setBaseTokenOriginChainId(block.chainid);

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.expectRevert(BaseTokenNativeToThisChain.selector);
        baseTokenHolder.recoverBaseToken(recipient, 1 ether, GATEWAY_CHAIN_ID);
    }

    function test_recoverBaseToken_zeroAmountIsNoop() public {
        uint256 holderBalanceBefore = address(baseTokenHolder).balance;

        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        baseTokenHolder.recoverBaseToken(recipient, 0, GATEWAY_CHAIN_ID);

        assertEq(recipient.balance, 0);
        assertEq(address(baseTokenHolder).balance, holderBalanceBefore);
    }

    /// @dev Recovery is NativeTokenVault-only — tighter than burnAndStartBridging (which also allows the
    /// InteropCenter). Neither the InteropCenter nor the InteropHandler may trigger a base-token recovery.
    function test_recoverBaseToken_revertFromInteropCenter() public {
        vm.prank(L2_INTEROP_CENTER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_INTEROP_CENTER_ADDR));
        baseTokenHolder.recoverBaseToken(recipient, 1 ether, GATEWAY_CHAIN_ID);
    }

    function test_recoverBaseToken_revertFromInteropHandler() public {
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_INTEROP_HANDLER_ADDR));
        baseTokenHolder.recoverBaseToken(recipient, 1 ether, GATEWAY_CHAIN_ID);
    }
}

/// @notice Helper contract that rejects ETH transfers via receive()
contract RejectingETHContract {
    receive() external payable {
        revert("Rejected");
    }
}

contract BookkeepingObservingRecipient {
    MockRecordingAssetTracker internal immutable TRACKER;
    uint256 public observedDeposits;

    constructor(MockRecordingAssetTracker _tracker) {
        TRACKER = _tracker;
    }

    receive() external payable {
        observedDeposits = TRACKER.recordedFromAmount();
    }
}
