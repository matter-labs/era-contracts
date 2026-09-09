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
    TX_SLOT_OVERHEAD_L2_GAS,
    USER_PRIORITY_TX_MAX_GAS_LIMIT,
    ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT
} from "contracts/common/Config.sol";
import {TooMuchGas} from "contracts/common/L1ContractErrors.sol";

/// @notice The bound on *user-supplied* L1->L2 gas limits.
///
/// Only `_requestL2Transaction` carries a user-controlled `l2GasLimit`, so only that path needs a
/// bound that does not depend on per-chain configuration. It is capped by
/// `USER_PRIORITY_TX_MAX_GAS_LIMIT` in addition to the per-chain `s.priorityTxMaxGasLimit`,
/// whichever is lower.
///
/// The authored paths (`_requestL2TransactionFree` for service txs and the Gateway relay wrap, plus
/// upgrade/genesis txs) build their own gas limit and stay on `s.priorityTxMaxGasLimit` alone.
contract MailboxUserPriorityTxGasCapTest is MailboxTest {
    /// Comfortably above the user cap and below the chain limit, so only the user cap can reject it.
    uint256 internal constant ABOVE_USER_CAP = USER_PRIORITY_TX_MAX_GAS_LIMIT + 5_000_000;
    /// Comfortably below the user cap, so nothing should reject it.
    uint256 internal constant BELOW_USER_CAP = USER_PRIORITY_TX_MAX_GAS_LIMIT - 5_000_000;
    /// The largest `l2GasLimit` the cap accepts for a request with empty calldata.
    uint256 internal constant MAX_ACCEPTED_GAS_LIMIT = USER_PRIORITY_TX_MAX_GAS_LIMIT + TX_SLOT_OVERHEAD_L2_GAS;

    function setUp() public virtual {
        setupDiamondProxy();
        utilsFacet.util_setBridgehub(bridgehub);
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        vm.deal(bridgehub, 1000 ether);
    }

    /// Pinned so that moving the constant is a deliberate act with a failing test attached.
    function test_userCapIsFifteenMillion() public pure {
        assertEq(USER_PRIORITY_TX_MAX_GAS_LIMIT, 15_000_000, "the user gas cap must not drift silently");
    }

    /// The cap is on transaction *body* gas: `getTransactionBodyGasLimit` subtracts the batch
    /// overhead before the comparison, so the largest accepted `l2GasLimit` is the cap plus that
    /// overhead. The request below encodes to 800 bytes, under the 1000 at which the per-byte
    /// `MEMORY_OVERHEAD_GAS` term overtakes `TX_SLOT_OVERHEAD_L2_GAS`, so the overhead is the slot
    /// one. Calldata or factory deps in the fixture would move the boundary.
    function test_userTxAtTheBodyGasBoundarySucceeds() public {
        utilsFacet.util_setPriorityTxMaxGasLimit(DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT);

        vm.prank(bridgehub);
        bytes32 canonicalTxHash = mailboxFacet.bridgehubRequestL2Transaction(_userRequest(MAX_ACCEPTED_GAS_LIMIT));
        assertTrue(canonicalTxHash != bytes32(0), "the cap bounds body gas, not the requested gas limit");
    }

    /// One gas past that boundary. Paired with the test above this pins the overhead the cap is
    /// measured against: capping the raw `l2GasLimit` fails the previous test, and measuring
    /// against a larger overhead fails this one.
    function test_revertWhen_userTxIsOneGasOverTheBodyGasBoundary() public {
        utilsFacet.util_setPriorityTxMaxGasLimit(DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT);

        vm.prank(bridgehub);
        vm.expectRevert(TooMuchGas.selector);
        mailboxFacet.bridgehubRequestL2Transaction(_userRequest(MAX_ACCEPTED_GAS_LIMIT + 1));
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

    /// On ZKsync OS the gas limit is not what bounds an L1 transaction's work: the bootloader
    /// clamps its native computational resources to a fixed ceiling. The chain's own
    /// `zksyncOSMaxTxGasLimit` default (2^24) already sits above the EraVM constant and an admin
    /// may raise it further, so applying the EraVM constant here would undercut it for no gain.
    function test_zksyncOSChainIsNotSubjectToTheEraVMUserCap() public {
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
