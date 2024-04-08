// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {TransactionValidator} from "contracts/state-transition/libraries/TransactionValidator.sol";

contract TransactionValidatorSharedTest is Test {
    constructor() {}

    function createTestTransaction() public pure returns (L2CanonicalTransaction memory testTx) {
        testTx = L2CanonicalTransaction({
            txType: 0,
            from: uint256(uint160(1_000_000_000)),
            to: uint256(uint160(0)),
            gasLimit: 500000,
            gasPerPubdataByteLimit: 800,
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
        });
    }

    function createUpgradeTransaction() public pure returns (L2CanonicalTransaction memory testTx) {
        testTx = createTestTransaction();
        testTx.from = uint256(0x8001);
        testTx.to = uint256(0x8007);
    }

    function validateL1ToL2Transaction(
        L2CanonicalTransaction memory _transaction,
        uint256 _priorityTxMaxGasLimit,
        uint256 _priorityTxMaxPubdata
    ) public pure {
        TransactionValidator.validateL1ToL2Transaction(
            _transaction,
            abi.encode(_transaction),
            _priorityTxMaxGasLimit,
            _priorityTxMaxPubdata
        );
    }

    function getOverheadForTransaction(uint256 _encodingLength) public pure returns (uint256) {
        return TransactionValidator.getOverheadForTransaction(_encodingLength);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
