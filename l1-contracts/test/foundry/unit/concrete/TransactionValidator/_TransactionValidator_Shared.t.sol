// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransactionValidatorTest} from "../../../../../cache/solpp-generated-contracts/dev-contracts/test/TransactionValidatorTest.sol";
import {IMailbox} from "../../../../../cache/solpp-generated-contracts/zksync/interfaces/IMailbox.sol";


contract TransactionValidatorSharedTest is Test {
    TransactionValidatorTest internal validator;

    constructor() {
        validator = new TransactionValidatorTest();
    }

    function createTestTransaction() public pure returns (IMailbox.L2CanonicalTransaction memory testTx){
        testTx = IMailbox.L2CanonicalTransaction(
            {
                txType: 0,
                from: uint256(uint160(0)),
                to: uint256(uint160(0)),
                gasLimit: 0,
                gasPerPubdataByteLimit: 0,
                maxFeePerGas: uint256(0),
                maxPriorityFeePerGas: uint256(0),
                paymaster: uint256(0),
                nonce: uint256(0),
                value: 0,
                reserved: [uint256(0), uint256(0), uint256(0), uint256(0)],
                data: new bytes(0),
                signature: new bytes(0),
                factoryDeps: new uint256[](0),
                paymasterInput: new bytes(0),
                reservedDynamic: new bytes(0)
            }
        );
    }
}
