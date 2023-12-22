pragma solidity 0.8.20;

import {TransactionValidatorSharedTest} from "./_TransactionValidator_Shared.t.sol";
import {IMailbox} from "../../../../../cache/solpp-generated-contracts/zksync/interfaces/IMailbox.sol";


contract ValidateL1L2TxTest is TransactionValidatorSharedTest {
    function test_hello() public view {
        IMailbox.L2CanonicalTransaction memory testTx = createTestTransaction();
        testTx.gasLimit = 600000;
        validator.validateL1ToL2Transaction(testTx, 500000);
    }

}
