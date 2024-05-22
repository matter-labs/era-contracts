// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {BridgehubL2TransactionRequest} from "contracts/common/Messaging.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, MAX_NEW_FACTORY_DEPS} from "contracts/common/Config.sol";
import {TransactionFiltererTrue} from "contracts/dev-contracts/test/DummyTransactionFiltererTrue.sol";
import {TransactionFiltererFalse} from "contracts/dev-contracts/test/DummyTransactionFiltererFalse.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

contract MailboxequestL2TransactionTest is MailboxTest {
    function setUp() public virtual {
        init();
    }

    function test_RevertWhen_NotEra() public {
        utilsFacet.util_setChainId(eraChainId + 1);

        address tempAddress = makeAddr("temp");
        bytes[] memory tempBytesArr = new bytes[](0);
        bytes memory tempBytes = "";

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
        utilsFacet.util_setChainId(eraChainId);

        address tempAddress = makeAddr("temp");
        bytes[] memory tempBytesArr = new bytes[](0);
        bytes memory tempBytes = "";

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
        utilsFacet.util_setChainId(eraChainId);

        address tempAddress = makeAddr("temp");
        bytes[] memory tempBytesArr = new bytes[](1);
        bytes memory tempBytes = "";

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
        utilsFacet.util_setChainId(eraChainId);

        address tempAddress = makeAddr("temp");
        bytes[] memory tempBytesArr = new bytes[](MAX_NEW_FACTORY_DEPS + 1);
        bytes memory tempBytes = "";

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
        utilsFacet.util_setChainId(eraChainId);
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);

        DummyBridgehub bridgeHub = new DummyBridgehub();
        address bridgehubAddress = address(bridgeHub);
        address l1WethAddress = makeAddr("l1Weth");
        address tempAddress = makeAddr("temp");

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = "11111111111111111111111111111111";
        bytes memory tempBytes = "";
        
        uint256 baseCost = mailboxFacet.l2TransactionBaseCost(10000000, 1000000, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        uint256 l2Value = 1 ether;
        uint256 mintValue = baseCost + l2Value;


        L1SharedBridge baseTokenBridge = new L1SharedBridge({
            _l1WethAddress: l1WethAddress,
            _bridgehub: IBridgehub(bridgehubAddress),
            _eraChainId: eraChainId,
            _eraDiamondProxy: diamondProxy
        });
        address baseTokenBridgeAddress = address(baseTokenBridge);
        utilsFacet.util_setBaseTokenBridge(baseTokenBridgeAddress);

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
