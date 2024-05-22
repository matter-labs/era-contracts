// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {BridgehubL2TransactionRequest} from "contracts/common/Messaging.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, MAX_NEW_FACTORY_DEPS, ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {TransactionFiltererTrue} from "contracts/dev-contracts/test/DummyTransactionFiltererTrue.sol";
import {TransactionFiltererFalse} from "contracts/dev-contracts/test/DummyTransactionFiltererFalse.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {IL1SharedBridge} from "contracts/bridge/interfaces/IL1SharedBridge.sol";

contract MailboxequestL2TransactionTest is MailboxTest {
    address tempAddress;
    bytes[] tempBytesArr;
    bytes tempBytes;

    function setUp() public virtual {
        prepare();

        tempAddress = makeAddr("temp");
        tempBytesArr = new bytes[](0);
        tempBytes = "";
        utilsFacet.util_setChainId(eraChainId);
    }

    function test_RevertWhen_NotEra() public {
        utilsFacet.util_setChainId(eraChainId + 1);

        vm.expectRevert("Mailbox: legacy interface only available for Era");
        mailboxFacet.requestL2Transaction({
            _contractL2: tempAddress,
            _l2Value: 0,
            _calldata: tempBytes,
            _l2GasLimit: 0,
            _l2GasPerPubdataByteLimit: 0,
            _factoryDeps: tempBytesArr,
            _refundRecipient: tempAddress
        });
    }

    function test_RevertWhen_wrongL2GasPerPubdataByteLimit() public {
        vm.expectRevert(bytes("qp"));
        mailboxFacet.requestL2Transaction({
            _contractL2: tempAddress,
            _l2Value: 0,
            _calldata: tempBytes,
            _l2GasLimit: 0,
            _l2GasPerPubdataByteLimit: 0,
            _factoryDeps: tempBytesArr,
            _refundRecipient: tempAddress
        });
    }

    function test_RevertWhen_msgValueDoesntCoverTx() public {
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        tempBytesArr = new bytes[](1);

        uint256 baseCost = mailboxFacet.l2TransactionBaseCost(10000000, 1000000, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        uint256 l2Value = 1 ether;
        uint256 mintValue = baseCost + l2Value;

        vm.expectRevert(bytes("mv"));
        mailboxFacet.requestL2Transaction{value: mintValue - 1}({
            _contractL2: tempAddress,
            _l2Value: l2Value,
            _calldata: tempBytes,
            _l2GasLimit: 1000000,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps: tempBytesArr,
            _refundRecipient: tempAddress
        });
    }

    function test_RevertWhen_factoryDepsLengthExceeded() public {
        tempBytesArr = new bytes[](MAX_NEW_FACTORY_DEPS + 1);

        vm.expectRevert(bytes("uj"));
        mailboxFacet.requestL2Transaction({
            _contractL2: tempAddress,
            _l2Value: 0,
            _calldata: tempBytes,
            _l2GasLimit: 0,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps: tempBytesArr,
            _refundRecipient: tempAddress
        });
    }

    function test_success_requestL2Transaction() public {
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = "11111111111111111111111111111111";

        uint256 baseCost = mailboxFacet.l2TransactionBaseCost(10000000, 1000000, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        uint256 l2Value = 1 ether;
        uint256 mintValue = baseCost + l2Value;

        address baseTokenBridge = makeAddr("baseTokenBridge");
        utilsFacet.util_setBaseTokenBridge(baseTokenBridge);

        vm.mockCall(
            baseTokenBridge,
            abi.encodeWithSelector(
                IL1SharedBridge.bridgehubDepositBaseToken.selector,
                eraChainId,
                sender,
                ETH_TOKEN_ADDRESS,
                mintValue
            ),
            ""
        );

        vm.deal(sender, mintValue);
        vm.prank(sender);
        bytes32 canonicalTxHash = mailboxFacet.requestL2Transaction{value: mintValue}({
            _contractL2: tempAddress,
            _l2Value: l2Value,
            _calldata: tempBytes,
            _l2GasLimit: 1000000,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps: factoryDeps,
            _refundRecipient: tempAddress
        });

        assertTrue(canonicalTxHash != bytes32(0), "canonicalTxHash should not be 0");
    }
}
