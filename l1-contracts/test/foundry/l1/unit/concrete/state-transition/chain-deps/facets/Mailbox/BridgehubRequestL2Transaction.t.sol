// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {BridgehubL2TransactionRequest} from "contracts/common/Messaging.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {TransactionFiltererTrue} from "contracts/dev-contracts/test/DummyTransactionFiltererTrue.sol";
import {TransactionFiltererFalse} from "contracts/dev-contracts/test/DummyTransactionFiltererFalse.sol";
import {TransactionNotAllowed, Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract MailboxBridgehubRequestL2TransactionTest is MailboxTest {
    function setUp() public virtual {
        setupDiamondProxy();
    }

    /// @dev The Mailbox authorizes the L1InteropCenter by resolving `interopCenter()` on the chain's
    /// bridgehub; the bridgehub here is a mock, so the resolution is mocked.
    function _mockInteropCenterResolution(address _bridgehub) private {
        vm.mockCall(_bridgehub, abi.encodeWithSelector(IL1Bridgehub.interopCenter.selector), abi.encode(interopCenter));
    }

    function test_success_withoutFilterer() public {
        address bridgehub = makeAddr("bridgehub");

        utilsFacet.util_setBridgehub(bridgehub);
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);
        _mockInteropCenterResolution(bridgehub);

        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();

        vm.deal(interopCenter, 100 ether);
        vm.prank(interopCenter);
        bytes32 canonicalTxHash = mailboxFacet.bridgehubRequestL2Transaction(req);
        assertTrue(canonicalTxHash != bytes32(0), "canonicalTxHash should not be 0");
    }

    function test_success_withFilterer() public {
        address bridgehub = makeAddr("bridgehub");
        TransactionFiltererTrue tf = new TransactionFiltererTrue();

        utilsFacet.util_setBridgehub(bridgehub);
        utilsFacet.util_setTransactionFilterer(address(tf));
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);
        _mockInteropCenterResolution(bridgehub);

        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();

        vm.deal(interopCenter, 100 ether);
        vm.prank(interopCenter);
        bytes32 canonicalTxHash = mailboxFacet.bridgehubRequestL2Transaction(req);
        assertTrue(canonicalTxHash != bytes32(0), "canonicalTxHash should not be 0");
    }

    function test_revertWhen_FalseFilterer() public {
        address bridgehub = makeAddr("bridgehub");
        TransactionFiltererFalse tf = new TransactionFiltererFalse();

        utilsFacet.util_setBridgehub(bridgehub);
        utilsFacet.util_setTransactionFilterer(address(tf));
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);
        _mockInteropCenterResolution(bridgehub);

        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();

        vm.deal(interopCenter, 100 ether);
        vm.prank(interopCenter);
        vm.expectRevert(TransactionNotAllowed.selector);
        mailboxFacet.bridgehubRequestL2Transaction(req);
    }

    function test_revertWhen_notInteropCenter() public {
        address bridgehub = makeAddr("bridgehub");
        utilsFacet.util_setBridgehub(bridgehub);
        _mockInteropCenterResolution(bridgehub);
        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();
        vm.deal(sender, 100 ether);
        vm.prank(address(sender));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, sender));
        mailboxFacet.bridgehubRequestL2Transaction(req);
    }

    function test_revertWhen_calledByBridgehub() public {
        // The bridgehub itself is no longer allowed to request L2 transactions: the L1InteropCenter
        // is the single entry point.
        address bridgehub = makeAddr("bridgehub");
        utilsFacet.util_setBridgehub(bridgehub);
        _mockInteropCenterResolution(bridgehub);

        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();

        vm.prank(bridgehub);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, bridgehub));
        mailboxFacet.bridgehubRequestL2Transaction(req);
    }

    function getBridgehubRequestL2TransactionRequest() private returns (BridgehubL2TransactionRequest memory req) {
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = "11111111111111111111111111111111";

        req = BridgehubL2TransactionRequest({
            sender: sender,
            contractL2: makeAddr("contractL2"),
            mintValue: 2 ether,
            l2Value: 10000,
            l2Calldata: "",
            l2GasLimit: 10000000,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            factoryDeps: factoryDeps,
            refundRecipient: sender
        });
    }

    function test_priorityTreeRootChange() public {
        bytes32 oldRootHash = gettersFacet.getPriorityTreeRoot();
        assertEq(oldRootHash, bytes32(0), "root hash should be 0");

        address bridgehub = makeAddr("bridgehub");

        utilsFacet.util_setBridgehub(bridgehub);
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);
        _mockInteropCenterResolution(bridgehub);

        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();

        vm.deal(interopCenter, 100 ether);
        vm.prank(interopCenter);
        bytes32 canonicalTxHash = mailboxFacet.bridgehubRequestL2Transaction(req);
        assertTrue(canonicalTxHash != bytes32(0), "canonicalTxHash should not be 0");

        bytes32 newRootHash = gettersFacet.getPriorityTreeRoot();
        assertEq(canonicalTxHash, newRootHash, "root hash should have changed");
    }
}
