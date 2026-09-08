// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CommitterFacet} from "../../state-transition/chain-deps/facets/Committer.sol";
import {PubdataPricingMode} from "../../state-transition/chain-deps/ZKChainStorage.sol";
import {LogProcessingOutput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfo} from "../../state-transition/chain-interfaces/ICommitter.sol";

contract CommitterProvingTest is CommitterFacet {
    constructor() CommitterFacet(block.chainid) {}

    /// @dev Test-only configuration. `_batchMetaParameters` and the commitment derivation read these
    /// from diamond storage, which a test would otherwise have to write by raw slot.
    function setBatchMetaParameters(
        bool _zkPorterIsAvailable,
        bytes32 _bootloaderHash,
        bytes32 _defaultAccountHash,
        bytes32 _evmEmulatorHash
    ) external {
        s.zkPorterIsAvailable = _zkPorterIsAvailable;
        s.l2BootloaderBytecodeHash = _bootloaderHash;
        s.l2DefaultAccountBytecodeHash = _defaultAccountHash;
        s.l2EvmEmulatorBytecodeHash = _evmEmulatorHash;
    }

    /// @dev Test-only: declares whether this chain commits Airbender data.
    function setMultiProofEnabled(bool _multiProofEnabled) external {
        s.multiProofEnabled = _multiProofEnabled;
    }

    function createBatchCommitment(
        CommitBatchInfo calldata _newBatchData,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) external view returns (bytes32) {
        (, , bytes32 commitment, ) = _createBatchCommitment(
            _newBatchData,
            _stateDiffHash,
            _blobCommitments,
            _blobHashes
        );
        return commitment;
    }

    /// @dev The Airbender-shape commitment the same call produces, so equivalence tests can pin the
    /// production derivation against externally recorded vectors rather than a copy of it.
    function createAirbenderBatchCommitment(
        CommitBatchInfo calldata _newBatchData,
        bytes32 _stateDiffHash,
        bytes32[] memory _blobCommitments,
        bytes32[] memory _blobHashes
    ) external view returns (bytes32) {
        (, , , bytes32 airbenderCommitment) = _createBatchCommitment(
            _newBatchData,
            _stateDiffHash,
            _blobCommitments,
            _blobHashes
        );
        return airbenderCommitment;
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
