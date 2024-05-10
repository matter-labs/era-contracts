## ExecutorProvingTest

### getBatchProofPublicInput

```solidity
function getBatchProofPublicInput(bytes32 _prevBatchCommitment, bytes32 _currentBatchCommitment) external pure returns (uint256)
```

### createBatchCommitment

```solidity
function createBatchCommitment(struct IExecutor.CommitBatchInfo _newBatchData, bytes32 _stateDiffHash, bytes32[] _blobCommitments, bytes32[] _blobHashes) external view returns (bytes32)
```

### processL2Logs

```solidity
function processL2Logs(struct IExecutor.CommitBatchInfo _newBatch, bytes32 _expectedSystemContractUpgradeTxHash, enum PubdataPricingMode) external pure returns (struct LogProcessingOutput logOutput)
```

### setHashes

```solidity
function setHashes(bytes32 l2DefaultAccountBytecodeHash, bytes32 l2BootloaderBytecodeHash) external
```

Sets the DefaultAccount Hash and Bootloader Hash.

