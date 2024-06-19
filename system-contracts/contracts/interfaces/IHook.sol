// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {Transaction} from '../libraries/TransactionHelper.sol';
import {IInitable} from '../interfaces/IInitable.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

interface IValidationHook is IInitable, IERC165 {
    function validationHook(
        bytes32 signedHash,
        Transaction calldata transaction,
        bytes calldata hookData
    ) external;
}

interface IExecutionHook is IInitable, IERC165 {
    function preExecutionHook(
        Transaction calldata transaction
    ) external returns (bytes memory context);

    function postExecutionHook(bytes memory context) external;
}
