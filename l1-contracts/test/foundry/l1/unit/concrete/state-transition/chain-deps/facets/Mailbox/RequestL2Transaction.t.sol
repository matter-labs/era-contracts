// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {BridgehubL2TransactionRequest} from "contracts/common/Messaging.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, MAX_NEW_FACTORY_DEPS, ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {TransactionFiltererTrue} from "contracts/dev-contracts/test/DummyTransactionFiltererTrue.sol";
import {TransactionFiltererFalse} from "contracts/dev-contracts/test/DummyTransactionFiltererFalse.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {DummySharedBridge} from "contracts/dev-contracts/test/DummySharedBridge.sol";
import {OnlyEraSupported, TooManyFactoryDeps, MsgValueTooLow, GasPerPubdataMismatch} from "contracts/common/L1ContractErrors.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";

contract MailboxRequestL2TransactionTest is MailboxTest {
    address tempAddress;
    bytes[] tempBytesArr;
    bytes tempBytes;
    DummySharedBridge l1SharedBridge;
    address baseTokenBridgeAddress;

    function setUp() public virtual {
        setupDiamondProxy();

        l1SharedBridge = new DummySharedBridge(keccak256("dummyDepositHash"));
        baseTokenBridgeAddress = address(l1SharedBridge);
        vm.mockCall(bridgehub, abi.encodeCall(Bridgehub.sharedBridge, ()), abi.encode(baseTokenBridgeAddress));

        tempAddress = makeAddr("temp");
        tempBytesArr = new bytes[](0);
        tempBytes = "";
        utilsFacet.util_setChainId(eraChainId);
    }

    function test_RevertWhen_NotEra(uint256 randomChainId) public {
        vm.assume(eraChainId != randomChainId);

        utilsFacet.util_setChainId(randomChainId);

        vm.expectRevert(OnlyEraSupported.selector);
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
        vm.expectRevert(GasPerPubdataMismatch.selector);
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

        vm.expectRevert(abi.encodeWithSelector(MsgValueTooLow.selector, mintValue, mintValue - 1));
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

        vm.expectRevert(TooManyFactoryDeps.selector);
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

    function _requestL2Transaction(
        uint256 amount,
        uint256 baseCost,
        uint256 l2GasLimit
    ) internal returns (bytes32 canonicalTxHash, uint256 mintValue) {
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = "11111111111111111111111111111111";

        mintValue = baseCost + amount;

        vm.deal(sender, mintValue);
        vm.prank(sender);
        canonicalTxHash = mailboxFacet.requestL2Transaction{value: mintValue}({
            _contractL2: tempAddress,
            _l2Value: amount,
            _calldata: tempBytes,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps: factoryDeps,
            _refundRecipient: tempAddress
        });
    }

    function test_RevertWhen_bridgePaused(uint256 randomValue) public {
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);

        uint256 l2GasLimit = 1000000;
        uint256 baseCost = mailboxFacet.l2TransactionBaseCost(10000000, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        randomValue = bound(randomValue, 0, type(uint256).max - baseCost);

        l1SharedBridge.pause();

        vm.expectRevert("Pausable: paused");
        _requestL2Transaction(randomValue, baseCost, l2GasLimit);
    }

    function test_success_requestL2Transaction(uint256 randomValue) public {
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setPriorityTxMaxGasLimit(100000000);

        uint256 l2GasLimit = 1000000;
        uint256 baseCost = mailboxFacet.l2TransactionBaseCost(10000000, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        randomValue = bound(randomValue, 0, type(uint256).max - baseCost);

        bytes32 canonicalTxHash;
        uint256 mintValue;

        (canonicalTxHash, mintValue) = _requestL2Transaction(randomValue, baseCost, l2GasLimit);
        assertTrue(canonicalTxHash != bytes32(0), "canonicalTxHash should not be 0");
        assertEq(baseTokenBridgeAddress.balance, mintValue);
        assertEq(l1SharedBridge.chainBalance(eraChainId, ETH_TOKEN_ADDRESS), mintValue);
    }
}
