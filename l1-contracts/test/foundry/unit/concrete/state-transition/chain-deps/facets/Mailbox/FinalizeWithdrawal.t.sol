// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IL1SharedBridge} from "contracts/bridge/interfaces/IL1SharedBridge.sol";

contract MailboxFinalizeWithdrawal is MailboxTest {
    bytes32[] proof;
    bytes message;

    function setUp() public virtual {
        prepare();

        proof = new bytes32[](0);
        message = "message";
    }

    function test_RevertWhen_notEra() public {
        utilsFacet.util_setChainId(eraChainId + 1);

        vm.expectRevert("Mailbox: finalizeEthWithdrawal only available for Era on mailbox");
        mailboxFacet.finalizeEthWithdrawal({
            _l2BatchNumber: 0,
            _l2MessageIndex: 0,
            _l2TxNumberInBatch: 0,
            _message: message,
            _merkleProof: proof
        });
    }

    function test_success_withdrawal() public {
        address baseTokenBridge = makeAddr("baseTokenBridge");
        utilsFacet.util_setChainId(eraChainId);
        utilsFacet.util_setBaseTokenBridge(baseTokenBridge);

        vm.mockCall(
            baseTokenBridge,
            abi.encodeWithSelector(IL1SharedBridge.finalizeWithdrawal.selector, eraChainId, 0, 0, 0, message, proof),
            ""
        );

        mailboxFacet.finalizeEthWithdrawal({
            _l2BatchNumber: 0,
            _l2MessageIndex: 0,
            _l2TxNumberInBatch: 0,
            _message: message,
            _merkleProof: proof
        });
    }
}
