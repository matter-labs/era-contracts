// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ExecutorFacet} from "../../state-transition/chain-deps/facets/Executor.sol";
import {VerifierParams, PubdataPricingMode} from "../../state-transition/chain-deps/ZkSyncStateTransitionStorage.sol";
import {LogProcessingOutput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {PubdataSource, LogProcessingOutput} from "../../state-transition/chain-interfaces/IExecutor.sol";

contract ExecutorProvingTest is ExecutorFacet {
    function getBatchProofPublicInput(
        bytes32 _prevBatchCommitment,
        bytes32 _currentBatchCommitment,
        VerifierParams memory _verifierParams
    ) external pure returns (uint256) {
        return _getBatchProofPublicInput(_prevBatchCommitment, _currentBatchCommitment, _verifierParams);
    }

    function createBatchCommitment(
        CommitBatchInfo calldata _newBatchData,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) external view returns (bytes32) {
        return _createBatchCommitment(_newBatchData, _stateDiffHash, _blobCommitments, _blobHashes);
    }

    function processL2Logs(
        CommitBatchInfo calldata _newBatch,
        bytes32 _expectedSystemContractUpgradeTxHash,
        PubdataPricingMode
    ) external pure returns (LogProcessingOutput memory logOutput) {
        return _processL2Logs(_newBatch, _expectedSystemContractUpgradeTxHash);
    }

    /// Sets the DefaultAccount Hash and Bootloader Hash.
    function setHashes(bytes32 l2DefaultAccountBytecodeHash, bytes32 l2BootloaderBytecodeHash) external {
        s.l2DefaultAccountBytecodeHash = l2DefaultAccountBytecodeHash;
        s.l2BootloaderBytecodeHash = l2BootloaderBytecodeHash;
        s.zkPorterIsAvailable = false;
    }
}
