// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

/* solhint-disable max-line-length */

import {BridgeheadMailboxTest} from "./_BridgeheadMailbox_Shared.t.sol";
import {IMailbox} from "../../../../../../cache/solpp-generated-contracts/bridgehead/chain-interfaces/IMailbox.sol";

/* solhint-enable max-line-length */

contract RequestL2TransactionTest is BridgeheadMailboxTest {
    address internal contractL2;
    uint256 internal l2Value;
    bytes internal calldataBytes;
    uint256 internal l2GasLimit;
    uint256 internal l2GasPerPubdataByteLimit;
    bytes[] internal factoryDeps;
    address internal refundRecipient;
    address internal msgSender;
    uint256 internal msgValue;

    function setUp() public {
        contractL2 = makeAddr("contractL2");
        l2Value = 123456789;
        calldataBytes = "calldataBytes";
        l2GasLimit = 234567890;
        l2GasPerPubdataByteLimit = 345678901;
        factoryDeps = new bytes[](1);
        refundRecipient = makeAddr("refundRecipient");
        msgSender = makeAddr("msgSender");
        vm.deal(msgSender, 100 ether);
        msgValue = 456789012;
    }

    function test_RevertWhen_InternalCallReverts() public {
        bytes memory revertMessage = "random revert";

        vm.mockCallRevert(
            bridgehead.getChainContract(chainId),
            msgValue,
            abi.encodeWithSelector(
                IMailbox.requestL2TransactionBridgehead.selector,
                msgSender,
                contractL2,
                l2Value,
                calldataBytes,
                l2GasLimit,
                l2GasPerPubdataByteLimit,
                factoryDeps,
                refundRecipient
            ),
            revertMessage
        );

        vm.expectCall(
            bridgehead.getChainContract(chainId),
            msgValue,
            abi.encodeWithSelector(
                IMailbox.requestL2TransactionBridgehead.selector,
                msgSender,
                contractL2,
                l2Value,
                calldataBytes,
                l2GasLimit,
                l2GasPerPubdataByteLimit,
                factoryDeps,
                refundRecipient
            )
        );

        vm.expectRevert(revertMessage);
        vm.startPrank(msgSender);
        bridgehead.requestL2Transaction{value: msgValue}(
            chainId,
            contractL2,
            l2Value,
            calldataBytes,
            l2GasLimit,
            l2GasPerPubdataByteLimit,
            factoryDeps,
            refundRecipient
        );
    }

    function test_ShouldReturnReceivedCanonicalTxHash() public {
        bytes32 expectedCanonicalTxHash = bytes32(uint256(123456789));

        vm.mockCall(
            bridgehead.getChainContract(chainId),
            msgValue,
            abi.encodeWithSelector(
                IMailbox.requestL2TransactionBridgehead.selector,
                msgSender,
                contractL2,
                l2Value,
                calldataBytes,
                l2GasLimit,
                l2GasPerPubdataByteLimit,
                factoryDeps,
                refundRecipient
            ),
            abi.encode(expectedCanonicalTxHash)
        );

        vm.expectCall(
            bridgehead.getChainContract(chainId),
            msgValue,
            abi.encodeWithSelector(
                IMailbox.requestL2TransactionBridgehead.selector,
                msgSender,
                contractL2,
                l2Value,
                calldataBytes,
                l2GasLimit,
                l2GasPerPubdataByteLimit,
                factoryDeps,
                refundRecipient
            )
        );

        vm.startPrank(msgSender);
        bytes32 canonicalTxHash = bridgehead.requestL2Transaction{value: msgValue}(
            chainId,
            contractL2,
            l2Value,
            calldataBytes,
            l2GasLimit,
            l2GasPerPubdataByteLimit,
            factoryDeps,
            refundRecipient
        );
        assertEq(canonicalTxHash, expectedCanonicalTxHash, "Canonical transaction hash should be returned");
    }
}
