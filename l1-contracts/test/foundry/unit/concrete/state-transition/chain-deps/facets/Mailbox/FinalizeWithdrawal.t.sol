pragma solidity 0.8.24;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";

contract MailboxFinalizeWithdrawal is MailboxTest {
    function test_RevertWhen_finalizeEthWithdrawalNotEra() public {
        utilsFacet.util_setChainId(eraChainId + 1);
        bytes32[] memory proof = new bytes32[](0);
        bytes memory message = "message";
        vm.expectRevert("Mailbox: finalizeEthWithdrawal only available for Era on mailbox");

        mailboxFacet.finalizeEthWithdrawal({
            _l2BatchNumber: 0,
            _l2MessageIndex: 0,
            _l2TxNumberInBatch: 0,
            _message: message,
            _merkleProof: proof
        });
    }
}
