// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CommitterFacet} from "../../state-transition/chain-deps/facets/Committer.sol";
import {PubdataPricingMode} from "../../state-transition/chain-deps/ZKChainStorage.sol";
import {LogProcessingOutput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfo} from "../../state-transition/chain-interfaces/ICommitter.sol";

contract CommitterProvingTest is CommitterFacet {
    constructor() CommitterFacet(block.chainid) {}

    function createBatchCommitment(
        CommitBatchInfo calldata _newBatchData,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) external view returns (bytes32) {
        (, , bytes32 commitment) = _createBatchCommitment(_newBatchData, _stateDiffHash, _blobCommitments, _blobHashes);
        return commitment;
    }

    function processL2Logs(
        CommitBatchInfo calldata _newBatch,
        bytes32 _expectedSystemContractUpgradeTxHash,
        PubdataPricingMode
    ) external view returns (LogProcessingOutput memory logOutput) {
        return _processL2Logs(_newBatch, _expectedSystemContractUpgradeTxHash);
    }

    /// Sets the DefaultAccount Hash, Bootloader Hash and EVM emulator Hash.
    function setHashes(
        bytes32 l2DefaultAccountBytecodeHash,
        bytes32 l2BootloaderBytecodeHash,
        bytes32 l2EvmEmulatorBytecode
    ) external {
        s.l2DefaultAccountBytecodeHash = l2DefaultAccountBytecodeHash;
        s.l2BootloaderBytecodeHash = l2BootloaderBytecodeHash;
        s.l2EvmEmulatorBytecodeHash = l2EvmEmulatorBytecode;
        s.zkPorterIsAvailable = false;
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
