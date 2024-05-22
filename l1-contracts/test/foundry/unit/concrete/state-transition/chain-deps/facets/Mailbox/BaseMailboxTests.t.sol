// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";


contract MailboxBaseTests is MailboxTest {
    function test_mailboxConstructor() public {
        MailboxFacet m = new MailboxFacet(eraChainId);
        assertEq(m.ERA_CHAIN_ID(), eraChainId);
    }

    // Test the l2TransactionBaseCost function
    function test_RevertWhen_badDenominatorInL2TransactionBaseCost() public {
        utilsFacet.util_setbaseTokenGasPriceMultiplierDenominator(0);

        uint256 gasPrice = 100;
        uint256 l2GasLimit = 10000;
        uint256 l2GasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

        vm.expectRevert("Mailbox: baseTokenGasPriceDenominator not set");
        mailboxFacet.l2TransactionBaseCost(gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);
    }

    function test_successful_getL2TransactionBaseCostPricingModeValidium() public {
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setBaseTokenGasPriceMultiplierNominator(1);

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

        uint256 l2TransactionBaseCost = 250125000000000;

        assertEq(
            mailboxFacet.l2TransactionBaseCost(gasPrice, l2GasLimit, l2GasPerPubdataByteLimit),
            l2TransactionBaseCost
        );
    }

    // currently returns max which is limit
    // TODO: specify parameters so minrequiredbasetoken would be close to limit
    function test_successful_getL2TransactionBaseCostPricingModeRollup() public {
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setBaseTokenGasPriceMultiplierNominator(1);

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

        uint256 l2TransactionBaseCost = 250125000000000;

        assertEq(
            mailboxFacet.l2TransactionBaseCost(gasPrice, l2GasLimit, l2GasPerPubdataByteLimit),
            l2TransactionBaseCost
        );
    }
}
