// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {BridgehubL2TransactionRequest} from "contracts/common/Messaging.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {
    DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    SERVICE_TX_MAX_GAS_LIMIT,
    USER_PRIORITY_TX_MAX_GAS_LIMIT,
    ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT
} from "contracts/common/Config.sol";
import {TooMuchGas} from "contracts/common/L1ContractErrors.sol";

/// @notice The DoS bound on *user-supplied* L1->L2 gas limits.
///
/// Only `_requestL2Transaction` carries a user-controlled `l2GasLimit`, and only that path can be
/// forced on the operator by anyone. It is therefore capped by `USER_PRIORITY_TX_MAX_GAS_LIMIT` in
/// addition to the per-chain `s.priorityTxMaxGasLimit`, whichever is lower.
///
/// The authored paths (`_requestL2TransactionFree` for service txs and the Gateway relay wrap, plus
/// upgrade/genesis txs) build their own gas limit and stay on `s.priorityTxMaxGasLimit` alone.
contract MailboxUserPriorityTxGasCapTest is MailboxTest {
    /// Comfortably above the user cap and below the chain limit, so only the user cap can reject it.
    uint256 internal constant ABOVE_USER_CAP = USER_PRIORITY_TX_MAX_GAS_LIMIT + 5_000_000;
    /// Comfortably below the user cap, so nothing should reject it.
    uint256 internal constant BELOW_USER_CAP = USER_PRIORITY_TX_MAX_GAS_LIMIT - 5_000_000;

    function setUp() public virtual {
        setupDiamondProxy();
        utilsFacet.util_setBridgehub(bridgehub);
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        vm.deal(bridgehub, 1000 ether);
    }

    /// Pinned so that moving the constant is a deliberate act with a failing test attached.
    function test_userCapIsFifteenMillion() public pure {
        assertEq(USER_PRIORITY_TX_MAX_GAS_LIMIT, 15_000_000, "the DoS bound must not drift silently");
    }

    /// The chain limit stays at the 72M a chain is seeded with, so a pass here would mean the user
    /// cap is not being consulted at all.
    function test_revertWhen_userTxExceedsUserCapUnderTheChainLimit() public {
        utilsFacet.util_setPriorityTxMaxGasLimit(DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT);

        vm.prank(bridgehub);
        vm.expectRevert(TooMuchGas.selector);
        mailboxFacet.bridgehubRequestL2Transaction(_userRequest(ABOVE_USER_CAP));
    }

    function test_userTxUnderUserCapSucceeds() public {
        utilsFacet.util_setPriorityTxMaxGasLimit(DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT);

        vm.prank(bridgehub);
        bytes32 canonicalTxHash = mailboxFacet.bridgehubRequestL2Transaction(_userRequest(BELOW_USER_CAP));
        assertTrue(canonicalTxHash != bytes32(0), "user tx under the cap must be accepted");
    }

    /// The cap is the lower of the two, so a chain configured below the constant keeps winning.
    function test_revertWhen_chainLimitIsStricterThanUserCap() public {
        utilsFacet.util_setPriorityTxMaxGasLimit(BELOW_USER_CAP / 2);

        vm.prank(bridgehub);
        vm.expectRevert(TooMuchGas.selector);
        mailboxFacet.bridgehubRequestL2Transaction(_userRequest(BELOW_USER_CAP));
    }

    /// ZKsync OS bounds every transaction via `zksyncOSMaxTxGasLimit`, which `Executor` commits to
    /// the batch public input, so the bound is enforced in-circuit rather than at L1 admission. Its
    /// default (2^24) is above the EraVM constant and a chain admin may raise it further, so
    /// applying the EraVM constant here would silently undercut a knob ZKsync OS added on purpose.
    function test_zksyncOSChainKeepsItsOwnPerTxBound() public {
        utilsFacet.util_setPriorityTxMaxGasLimit(DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT);
        utilsFacet.util_setZksyncOS(true);

        // Above the EraVM user cap, below ZKsync OS's own default per-tx limit.
        uint256 gasLimit = USER_PRIORITY_TX_MAX_GAS_LIMIT + 1_000_000;
        assertLt(gasLimit, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT, "fixture must sit under the ZKsync OS limit");

        vm.prank(bridgehub);
        bytes32 canonicalTxHash = mailboxFacet.bridgehubRequestL2Transaction(_userRequest(gasLimit));
        assertTrue(canonicalTxHash != bytes32(0), "ZKsync OS chains must not inherit the EraVM cap");
    }

    /// Service txs hardcode `SERVICE_TX_MAX_GAS_LIMIT`, well above the user cap. They must remain
    /// unaffected, otherwise asset-migration confirmations and chain registration break.
    function test_serviceTxIsNotSubjectToTheUserCap() public {
        utilsFacet.util_setPriorityTxMaxGasLimit(SERVICE_TX_MAX_GAS_LIMIT);
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainRegistrationSender.selector),
            abi.encode(address(this))
        );

        bytes32 canonicalTxHash = IMailboxImpl(address(mailboxFacet)).requestL2ServiceTransaction(
            makeAddr("contractL2"),
            bytes("")
        );
        assertTrue(canonicalTxHash != bytes32(0), "service tx must stay on the chain limit");
    }

    function _userRequest(uint256 _l2GasLimit) private returns (BridgehubL2TransactionRequest memory) {
        return
            BridgehubL2TransactionRequest({
                sender: sender,
                contractL2: makeAddr("contractL2"),
                mintValue: 100 ether,
                l2Value: 0,
                l2Calldata: "",
                l2GasLimit: _l2GasLimit,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                factoryDeps: new bytes[](0),
                refundRecipient: sender
            });
    }
}
