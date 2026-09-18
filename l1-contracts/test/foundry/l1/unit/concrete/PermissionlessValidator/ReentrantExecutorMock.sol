// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PermissionlessValidator} from "contracts/state-transition/validators/PermissionlessValidator.sol";

contract ReentrantExecutorMock {
    PermissionlessValidator internal validator;
    bytes internal storedProveData;
    bytes internal storedExecuteData;
    bool internal attemptReenter;

    constructor(PermissionlessValidator _validator) {
        validator = _validator;
    }

    function setReenterPayload(bytes calldata proveData, bytes calldata executeData) external {
        storedProveData = proveData;
        storedExecuteData = executeData;
        attemptReenter = true;
    }

    function commitBatchesSharedBridge(
        address,
        uint256 _processFrom,
        uint256 _processTo,
        bytes calldata _commitData
    ) external {
        if (!attemptReenter) {
            return;
        }

        attemptReenter = false;
        validator.settleBatchesSharedBridge({_chainAddress: address(this), _processBatchFrom: _processFrom, _processBatchTo: _processTo, _commitData: _commitData, _proveData: storedProveData, _executeData: storedExecuteData});
    }

    function proveBatchesSharedBridge(address, uint256, uint256, bytes calldata) external {}

    function executeBatchesSharedBridge(address, uint256, uint256, bytes calldata) external {}
}
