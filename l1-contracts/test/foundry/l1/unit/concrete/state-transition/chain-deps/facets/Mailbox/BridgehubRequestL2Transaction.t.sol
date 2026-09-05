// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {BridgehubL2TransactionRequest, L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {TransactionFiltererTrue} from "contracts/dev-contracts/test/DummyTransactionFiltererTrue.sol";
import {TransactionFiltererFalse} from "contracts/dev-contracts/test/DummyTransactionFiltererFalse.sol";
import {TransactionNotAllowed, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {LogFinder} from "test-utils/LogFinder.sol";
import {NEW_PRIORITY_REQUEST_SIGNATURE} from "test/foundry/TestConstants.sol";

contract MailboxBridgehubRequestL2TransactionTest is MailboxTest {
    using LogFinder for Vm.Log[];

    function setUp() public virtual {
        setupDiamondProxy();
    }

    function test_success_withoutFilterer() public {
        address bridgehub = makeAddr("bridgehub");

        utilsFacet.util_setBridgehub(bridgehub);
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);

        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();

        vm.deal(interopCenter, 100 ether);
        vm.prank(address(bridgehub));
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

        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();

        vm.deal(interopCenter, 100 ether);
        vm.prank(address(bridgehub));
        bytes32 canonicalTxHash = mailboxFacet.bridgehubRequestL2Transaction(req);
        assertTrue(canonicalTxHash != bytes32(0), "canonicalTxHash should not be 0");
    }

    function test_success_serializesArbitraryLengthFactoryDepsWithObservableHashes() public {
        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(req.l2GasLimit);

        req.factoryDeps = new bytes[](2);
        req.factoryDeps[0] = hex"6001600055";
        req.factoryDeps[1] = new bytes(33);
        req.factoryDeps[1][0] = 0x60;
        req.factoryDeps[1][32] = 0x00;

        vm.recordLogs();
        vm.prank(bridgehub);
        bytes32 canonicalTxHash = mailboxFacet.bridgehubRequestL2Transaction(req);

        Vm.Log memory log = vm.getRecordedLogs().requireOneFrom(NEW_PRIORITY_REQUEST_SIGNATURE, address(mailboxFacet));
        (
            uint256 txId,
            bytes32 emittedTxHash,
            uint64 expirationTimestamp,
            L2CanonicalTransaction memory transaction,
            bytes[] memory emittedFactoryDeps
        ) = abi.decode(log.data, (uint256, bytes32, uint64, L2CanonicalTransaction, bytes[]));

        assertEq(txId, 0);
        assertEq(expirationTimestamp, 0);
        assertEq(emittedFactoryDeps.length, req.factoryDeps.length);
        assertEq(transaction.factoryDeps.length, req.factoryDeps.length);
        for (uint256 i = 0; i < req.factoryDeps.length; ++i) {
            assertEq(emittedFactoryDeps[i], req.factoryDeps[i]);
            assertEq(transaction.factoryDeps[i], uint256(keccak256(req.factoryDeps[i])));
        }
        assertEq(emittedTxHash, keccak256(abi.encode(transaction)));
        assertEq(canonicalTxHash, emittedTxHash);
        assertEq(gettersFacet.getPriorityTreeRoot(), canonicalTxHash);
    }

    function test_revertWhen_FalseFilterer() public {
        address bridgehub = makeAddr("bridgehub");
        TransactionFiltererFalse tf = new TransactionFiltererFalse();

        utilsFacet.util_setBridgehub(bridgehub);
        utilsFacet.util_setTransactionFilterer(address(tf));
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);

        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();

        vm.deal(interopCenter, 100 ether);
        vm.prank(address(bridgehub));
        vm.expectRevert(TransactionNotAllowed.selector);
        mailboxFacet.bridgehubRequestL2Transaction(req);
    }

    function test_revertWhen_notBridgehub() public {
        address bridgehub = makeAddr("bridgehub");
        utilsFacet.util_setBridgehub(bridgehub);
        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();
        vm.deal(bridgehub, 100 ether);
        vm.prank(address(sender));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, sender));
        mailboxFacet.bridgehubRequestL2Transaction(req);
    }

    function test_revertWhen_calledByInteropCenter() public {
        address bridgehub = makeAddr("bridgehub");
        utilsFacet.util_setBridgehub(bridgehub);

        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();

        vm.prank(interopCenter);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, interopCenter));
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

        address oldBridgehub = address(bridgehub);
        address bridgehub = makeAddr("bridgehub");

        utilsFacet.util_setBridgehub(bridgehub);
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);

        BridgehubL2TransactionRequest memory req = getBridgehubRequestL2TransactionRequest();

        vm.deal(interopCenter, 100 ether);
        vm.prank(address(oldBridgehub));
        bytes32 canonicalTxHash = mailboxFacet.bridgehubRequestL2Transaction(req);
        assertTrue(canonicalTxHash != bytes32(0), "canonicalTxHash should not be 0");

        bytes32 newRootHash = gettersFacet.getPriorityTreeRoot();
        assertEq(canonicalTxHash, newRootHash, "root hash should have changed");
    }
}
