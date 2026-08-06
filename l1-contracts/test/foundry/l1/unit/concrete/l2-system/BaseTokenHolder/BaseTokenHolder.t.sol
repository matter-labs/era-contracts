// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BaseTokenHolder} from "contracts/l2-system/BaseTokenHolder.sol";
import {IBaseTokenHolder} from "contracts/l2-system/interfaces/IBaseTokenHolder.sol";
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
    InvalidCaller,
    RecoverToL1NotSupported,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";

/// @dev Mock NativeTokenVault that records the base-token bridge flows the holder reports.
/// The settlement-layer gating of these flows lives in the real vault and is covered by the
/// L2NativeTokenVault tests; here we only verify what the holder forwards.
contract MockRecordingNativeTokenVault {
    uint256 internal constant MOCK_L1_CHAIN_ID = 9;
    bytes32 internal constant MOCK_BASE_TOKEN_ASSET_ID = bytes32(uint256(0xba5e));

    uint256 public recordedToChainId;
    uint256 public recordedToAmount;
    uint256 public toChainCalls;

    uint256 public recordedFromChainId;
    uint256 public recordedFromAmount;
    uint256 public fromChainCalls;

    uint256 internal baseTokenOriginChainId = MOCK_L1_CHAIN_ID;

    function recordBaseTokenBridgingToChain(uint256 _toChainId, uint256 _amount) external {
        if (msg.sender != _holder()) {
            revert InvalidCaller(msg.sender);
        }
        recordedToChainId = _toChainId;
        recordedToAmount = _amount;
        toChainCalls++;
    }

    function recordBaseTokenBridgingFromChain(uint256 _fromChainId, uint256 _amount) external {
        if (msg.sender != _holder()) {
            revert InvalidCaller(msg.sender);
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
    MockRecordingNativeTokenVault internal vault;

    address internal recipient;
    uint256 internal constant INITIAL_BALANCE = 100 ether;
    uint256 internal constant L1_CHAIN_ID = 9;
    uint256 internal constant ERA_CHAIN_ID = 271;
    uint256 internal constant GATEWAY_CHAIN_ID = 505;

    function setUp() public {
        baseTokenHolder = new BaseTokenHolder();
        recipient = makeAddr("recipient");

        // The holder reports every bridge flow to the vault; a recording mock stands in for it.
        MockRecordingNativeTokenVault vaultImpl = new MockRecordingNativeTokenVault();
        vm.etch(L2_NATIVE_TOKEN_VAULT_ADDR, address(vaultImpl).code);
        vault = MockRecordingNativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        vault.setHolder(address(baseTokenHolder));

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
        assertEq(vault.fromChainCalls(), 0, "zero-amount give must not be reported to the vault");
    }

    function test_give_reportsInboundFlowToVault() public {
        uint256 amount = 1 ether;

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(recipient, amount, L1_CHAIN_ID);

        assertEq(vault.fromChainCalls(), 1, "inbound flow should be reported exactly once");
        assertEq(vault.recordedFromChainId(), L1_CHAIN_ID, "source chain id should be forwarded verbatim");
        assertEq(vault.recordedFromAmount(), amount, "amount should be forwarded verbatim");
    }

    function test_give_revertWhenRecipientRejectsETH() public {
        uint256 amount = 1 ether;

        // Deploy a contract that rejects ETH
        RejectingETHContract rejecting = new RejectingETHContract();

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert("Address: unable to send value, recipient may have reverted");
        baseTokenHolder.give(address(rejecting), amount, L1_CHAIN_ID);

        assertEq(vault.fromChainCalls(), 0, "reverted transfer must revert bookkeeping");
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

    /// @dev L2BaseToken is an authorized bridging caller: its `withdraw`/`withdrawWithMessage` entrypoints
    /// burn the sent value by forwarding it to the BaseTokenHolder via `burnAndStartBridging`.
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

    function test_burnAndStartBridging_reportsOutboundFlowToVault() public {
        uint256 amount = 2 ether;

        vm.deal(L2_INTEROP_CENTER_ADDR, amount);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        baseTokenHolder.burnAndStartBridging{value: amount}(L1_CHAIN_ID);

        assertEq(vault.toChainCalls(), 1, "outbound flow should be reported exactly once");
        assertEq(vault.recordedToChainId(), L1_CHAIN_ID, "destination chain id should be forwarded verbatim");
        assertEq(vault.recordedToAmount(), amount, "amount should be forwarded verbatim");
    }

    function test_burnAndStartBridging_zeroValueIsNotReported() public {
        vm.prank(L2_INTEROP_CENTER_ADDR);
        baseTokenHolder.burnAndStartBridging{value: 0}(L1_CHAIN_ID);

        assertEq(vault.toChainCalls(), 0, "zero-value burn must not be reported to the vault");
    }

    /*//////////////////////////////////////////////////////////////
                    ORDERING INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that inbound bookkeeping is updated before control reaches the recipient.
    function test_give_recordsDepositBeforeTransfer() public {
        uint256 amount = 1 ether;
        BookkeepingObservingRecipient observer = new BookkeepingObservingRecipient(vault);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        baseTokenHolder.give(address(observer), amount, L1_CHAIN_ID);

        assertEq(observer.observedDeposits(), amount, "recipient should observe the completed bookkeeping");
        assertEq(address(observer).balance, amount, "recipient should receive ETH after bookkeeping");
    }

    /*//////////////////////////////////////////////////////////////
                    recordBaseTokenDeposit() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_recordBaseTokenDeposit_onlyL2BaseToken() public {
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        baseTokenHolder.recordBaseTokenDeposit(L1_CHAIN_ID, 17);

        assertEq(vault.fromChainCalls(), 1, "bootloader deposit should be reported to the vault");
        assertEq(vault.recordedFromChainId(), L1_CHAIN_ID);
        assertEq(vault.recordedFromAmount(), 17);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        baseTokenHolder.recordBaseTokenDeposit(L1_CHAIN_ID, 1);
    }

    function test_recordBaseTokenDeposit_zeroAmountIsNotReported() public {
        vm.prank(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        baseTokenHolder.recordBaseTokenDeposit(L1_CHAIN_ID, 0);

        assertEq(vault.fromChainCalls(), 0, "zero-amount deposit must not be reported to the vault");
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

    /// @dev The base token never originates from this chain, so `L2NativeTokenVault.bridgedOut` holds
    /// nothing to re-credit; a chain-native base token would invalidate that assumption.
    function test_recoverBaseToken_revertsWhenBaseTokenIsNativeToThisChain() public {
        vault.setBaseTokenOriginChainId(block.chainid);

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
    MockRecordingNativeTokenVault internal immutable vault;
    uint256 public observedDeposits;

    constructor(MockRecordingNativeTokenVault _vault) {
        vault = _vault;
    }

    receive() external payable {
        observedDeposits = vault.recordedFromAmount();
    }
}
