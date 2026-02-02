// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {IExecutor} from "../chain-interfaces/IExecutor.sol";
import {ICommitter} from "../chain-interfaces/ICommitter.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Smart contract used as an entry point for settling batches in Priority Mode.
/// It allows anyone to commit, prove, and execute batches in one go.
///
/// @dev The smart contract is intended to be used for Stage 1 ZK chains when their operators
/// fail to process priority transactions and priority mode is activated.
/// The chain contract is responsible for enforcing proper access control
/// (i.e., ensuring that only this contract can settle batches after Priority Mode is entered).
contract PermissionlessValidator is ReentrancyGuard {
    constructor() reentrancyGuardInitializer {}

    /// @notice Commit, prove, and execute the same batch range atomically.
    /// @param _chainAddress The ZKsync chain contract address where to settle batches.
    /// @param _processBatchFrom The first batch in the range.
    /// @param _processBatchTo The last batch in the range.
    /// @param _commitData The calldata blob for the commit step.
    /// @param _proveData The calldata blob for the prove step.
    /// @param _executeData The calldata blob for the execute step.
    function settleBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _commitData,
        bytes calldata _proveData,
        bytes calldata _executeData
    ) external nonReentrant {
        ICommitter(_chainAddress).commitBatchesSharedBridge(
            _chainAddress,
            _processBatchFrom,
            _processBatchTo,
            _commitData
        );
        IExecutor(_chainAddress).proveBatchesSharedBridge(
            _chainAddress,
            _processBatchFrom,
            _processBatchTo,
            _proveData
        );
        IExecutor(_chainAddress).executeBatchesSharedBridge(
            _chainAddress,
            _processBatchFrom,
            _processBatchTo,
            _executeData
        );
    }
}
