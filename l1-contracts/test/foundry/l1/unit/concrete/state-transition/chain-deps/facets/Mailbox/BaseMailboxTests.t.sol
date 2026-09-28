// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {
    PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    SERVICE_TRANSACTION_SENDER,
    SETTLEMENT_LAYER_RELAY_SENDER
} from "contracts/common/Config.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {DummyZKChain} from "contracts/dev-contracts/test/DummyZKChain.sol";
import {BaseTokenGasPriceDenominatorNotSet, ValueMismatch} from "contracts/common/L1ContractErrors.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {LogFinder} from "test-utils/LogFinder.sol";
import {NEW_PRIORITY_REQUEST_SIGNATURE} from "test/foundry/TestConstants.sol";

contract MailboxBaseTests is MailboxTest {
    using LogFinder for Vm.Log[];

    function setUp() public virtual {
        setupDiamondProxy();
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setBaseTokenGasPriceMultiplierNominator(1);
    }

    function test_RevertWhen_badDenominatorInL2TransactionBaseCost() public {
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(0);
        vm.expectRevert(BaseTokenGasPriceDenominatorNotSet.selector);
        mailboxFacet.l2TransactionBaseCost(100, 10000, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
    }

    function test_successful_getL2TransactionBaseCostPricingModeValidium() public {
        uint256 gasPrice = 10000000;
        uint256 l2GasLimit = 1000000;
        uint256 l2GasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

        FeeParams memory feeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Validium,
            batchOverheadL1Gas: 1000000,
            maxPubdataPerBatch: 120000,
            maxL2GasPerBatch: 80000000,
            priorityTxMaxPubdata: 99000,
            minimalL2GasPrice: 250000000
        });

        utilsFacet.util_setFeeParams(feeParams);

        // this was get from running the function, but more reasonable would be to
        // have some invariants that the calculation should keep for min required gas
        // price and also gas limit
        uint256 l2TransactionBaseCost = 250125000000000;

        assertEq(
            mailboxFacet.l2TransactionBaseCost(gasPrice, l2GasLimit, l2GasPerPubdataByteLimit),
            l2TransactionBaseCost
        );
    }

    function test_successful_getL2TransactionBaseCostPricingModeRollup() public {
        uint256 gasPrice = 10000000;
        uint256 l2GasLimit = 1000000;
        uint256 l2GasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

        FeeParams memory feeParams = FeeParams({
            pubdataPricingMode: PubdataPricingMode.Rollup,
            batchOverheadL1Gas: 1000000,
            maxPubdataPerBatch: 120000,
            maxL2GasPerBatch: 80000000,
            priorityTxMaxPubdata: 99000,
            minimalL2GasPrice: 250000000
        });

        utilsFacet.util_setFeeParams(feeParams);

        // this was get from running the function, but more reasonable would be to
        // have some invariants that the calculation should keep for min required gas
        // price and also gas limit
        uint256 l2TransactionBaseCost = 250125000000000;

        assertEq(
            mailboxFacet.l2TransactionBaseCost(gasPrice, l2GasLimit, l2GasPerPubdataByteLimit),
            l2TransactionBaseCost
        );
    }

    function test_requestL2TransactionToGatewayMailbox_RevertWhen_ExpirationTimestampNotZero() public {
        uint256 chainId = 42;
        utilsFacet.util_setChainId(eraChainId);

        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.whitelistedSettlementLayers.selector, eraChainId),
            abi.encode(true)
        );
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(sender)
        );

        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(ValueMismatch.selector, 0, 1));
        IMailbox(address(mailboxFacet)).requestL2TransactionToGatewayMailbox(chainId, bytes32(0), 1);
    }

    function test_serviceTransactionUsesProtocolGasCeiling() public {
        // Isolate mailbox admission from Bridgehub's service-sender configuration.
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.chainRegistrationSender, ()), abi.encode(address(this)));
        address target = makeAddr("serviceTarget");
        bytes memory data = hex"12345678";

        vm.recordLogs();
        bytes32 txHash = mailboxFacet.requestL2ServiceTransaction(target, data);

        L2CanonicalTransaction memory transaction = _assertFreePriorityRequest(txHash);
        assertEq(transaction.from, uint256(uint160(SERVICE_TRANSACTION_SENDER)));
        assertEq(transaction.to, uint256(uint160(target)));
        assertEq(transaction.data, data);
    }

    function test_gatewayRelayUsesProtocolGasCeiling() public {
        // Isolate wrapper construction from Bridgehub's chain registration and eligibility checks.
        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.whitelistedSettlementLayers, (gettersFacet.getChainId())),
            abi.encode(true)
        );
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getZKChain, (eraChainId)), abi.encode(sender));
        bytes32 relayedTxHash = keccak256("relayed priority transaction");

        vm.recordLogs();
        vm.prank(sender);
        bytes32 txHash = mailboxFacet.requestL2TransactionToGatewayMailbox(eraChainId, relayedTxHash, 0);

        L2CanonicalTransaction memory transaction = _assertFreePriorityRequest(txHash);
        assertEq(transaction.from, uint256(uint160(SETTLEMENT_LAYER_RELAY_SENDER)));
        assertEq(transaction.to, uint256(uint160(L2_INTEROP_CENTER_ADDR)));
        assertEq(
            transaction.data,
            abi.encodeCall(IInteropCenter.forwardTransactionOnGateway, (eraChainId, relayedTxHash, 0))
        );
    }

    function _assertFreePriorityRequest(bytes32 _txHash) internal returns (L2CanonicalTransaction memory transaction) {
        Vm.Log memory log = vm.getRecordedLogs().requireOneFrom(NEW_PRIORITY_REQUEST_SIGNATURE, address(mailboxFacet));
        (uint256 txId, bytes32 emittedTxHash, , L2CanonicalTransaction memory emittedTx, ) = abi.decode(
            log.data,
            (uint256, bytes32, uint64, L2CanonicalTransaction, bytes[])
        );
        assertEq(txId, 0);
        assertEq(emittedTx.gasLimit, PRIORITY_TX_MAX_GAS_LIMIT);
        assertEq(emittedTx.maxFeePerGas, 0);
        assertEq(emittedTxHash, keccak256(abi.encode(emittedTx)));
        assertEq(_txHash, emittedTxHash);
        assertEq(gettersFacet.getPriorityTreeRoot(), _txHash);
        assertEq(gettersFacet.getTotalPriorityTxs(), 1);
        return emittedTx;
    }
}
