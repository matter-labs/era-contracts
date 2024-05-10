## ExecutorFacet

### getName

```solidity
string getName
```

| Name | Type | Description |
| ---- | ---- | ----------- |

### _commitOneBatch

```solidity
function _commitOneBatch(struct IExecutor.StoredBatchInfo _previousBatch, struct IExecutor.CommitBatchInfo _newBatch, bytes32 _expectedSystemContractUpgradeTxHash) internal view returns (struct IExecutor.StoredBatchInfo)
```

Does not change storage

_Process one batch commit using the previous batch StoredBatchInfo
returns new batch StoredBatchInfo_

### _verifyBatchTimestamp

```solidity
function _verifyBatchTimestamp(uint256 _packedBatchAndL2BlockTimestamp, uint256 _expectedBatchTimestamp, uint256 _previousBatchTimestamp) internal view
```

checks that the timestamps of both the new batch and the new L2 block are correct.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _packedBatchAndL2BlockTimestamp | uint256 | - packed batch and L2 block timestamp in a format of batchTimestamp * 2**128 + l2BatchTimestamp |
| _expectedBatchTimestamp | uint256 | - expected batch timestamp |
| _previousBatchTimestamp | uint256 | - the timestamp of the previous batch |

### _processL2Logs

```solidity
function _processL2Logs(struct IExecutor.CommitBatchInfo _newBatch, bytes32 _expectedSystemContractUpgradeTxHash) internal pure returns (struct LogProcessingOutput logOutput)
```

_Check that L2 logs are proper and batch contain all meta information for them
The logs processed here should line up such that only one log for each key from the
     SystemLogKey enum in Constants.sol is processed per new batch.
Data returned from here will be used to form the batch commitment._

### commitBatches

```solidity
function commitBatches(struct IExecutor.StoredBatchInfo _lastCommittedBatchData, struct IExecutor.CommitBatchInfo[] _newBatchesData) external
```

Function called by the operator to commit new batches. It is responsible for:
- Verifying the correctness of their timestamps.
- Processing their L2->L1 logs.
- Storing batch commitments.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _lastCommittedBatchData | struct IExecutor.StoredBatchInfo | Stored data of the last committed batch. |
| _newBatchesData | struct IExecutor.CommitBatchInfo[] | Data of the new batches to be committed. |

### commitBatchesSharedBridge

```solidity
function commitBatchesSharedBridge(uint256, struct IExecutor.StoredBatchInfo _lastCommittedBatchData, struct IExecutor.CommitBatchInfo[] _newBatchesData) external
```

same as `commitBatches` but with the chainId so ValidatorTimelock can sort the inputs.

### _commitBatches

```solidity
function _commitBatches(struct IExecutor.StoredBatchInfo _lastCommittedBatchData, struct IExecutor.CommitBatchInfo[] _newBatchesData) internal
```

### _commitBatchesWithoutSystemContractsUpgrade

```solidity
function _commitBatchesWithoutSystemContractsUpgrade(struct IExecutor.StoredBatchInfo _lastCommittedBatchData, struct IExecutor.CommitBatchInfo[] _newBatchesData) internal
```

_Commits new batches without any system contracts upgrade._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _lastCommittedBatchData | struct IExecutor.StoredBatchInfo | The data of the last committed batch. |
| _newBatchesData | struct IExecutor.CommitBatchInfo[] | An array of batch data that needs to be committed. |

### _commitBatchesWithSystemContractsUpgrade

```solidity
function _commitBatchesWithSystemContractsUpgrade(struct IExecutor.StoredBatchInfo _lastCommittedBatchData, struct IExecutor.CommitBatchInfo[] _newBatchesData, bytes32 _systemContractUpgradeTxHash) internal
```

_Commits new batches with a system contracts upgrade transaction._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _lastCommittedBatchData | struct IExecutor.StoredBatchInfo | The data of the last committed batch. |
| _newBatchesData | struct IExecutor.CommitBatchInfo[] | An array of batch data that needs to be committed. |
| _systemContractUpgradeTxHash | bytes32 | The transaction hash of the system contract upgrade. |

### _collectOperationsFromPriorityQueue

```solidity
function _collectOperationsFromPriorityQueue(uint256 _nPriorityOps) internal returns (bytes32 concatHash)
```

_Pops the priority operations from the priority queue and returns a rolling hash of operations_

### _executeOneBatch

```solidity
function _executeOneBatch(struct IExecutor.StoredBatchInfo _storedBatch, uint256 _executedBatchIdx) internal
```

_Executes one batch
1. Processes all pending operations (Complete priority requests)
2. Finalizes batch on Ethereum
_executedBatchIdx is an index in the array of the batches that we want to execute together_

### executeBatchesSharedBridge

```solidity
function executeBatchesSharedBridge(uint256, struct IExecutor.StoredBatchInfo[] _batchesData) external
```

same as `executeBatches` but with the chainId so ValidatorTimelock can sort the inputs.

### executeBatches

```solidity
function executeBatches(struct IExecutor.StoredBatchInfo[] _batchesData) external
```

The function called by the operator to finalize (execute) batches. It is responsible for:
- Processing all pending operations (commpleting priority requests).
- Finalizing this batch (i.e. allowing to withdraw funds from the system)

| Name | Type | Description |
| ---- | ---- | ----------- |
| _batchesData | struct IExecutor.StoredBatchInfo[] | Data of the batches to be executed. |

### _executeBatches

```solidity
function _executeBatches(struct IExecutor.StoredBatchInfo[] _batchesData) internal
```

### proveBatches

```solidity
function proveBatches(struct IExecutor.StoredBatchInfo _prevBatch, struct IExecutor.StoredBatchInfo[] _committedBatches, struct IExecutor.ProofInput _proof) external
```

Batches commitment verification.

_Only verifies batch commitments without any other processing._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _prevBatch | struct IExecutor.StoredBatchInfo | Stored data of the last committed batch. |
| _committedBatches | struct IExecutor.StoredBatchInfo[] | Stored data of the committed batches. |
| _proof | struct IExecutor.ProofInput | The zero knowledge proof. |

### proveBatchesSharedBridge

```solidity
function proveBatchesSharedBridge(uint256, struct IExecutor.StoredBatchInfo _prevBatch, struct IExecutor.StoredBatchInfo[] _committedBatches, struct IExecutor.ProofInput _proof) external
```

same as `proveBatches` but with the chainId so ValidatorTimelock can sort the inputs.

### _proveBatches

```solidity
function _proveBatches(struct IExecutor.StoredBatchInfo _prevBatch, struct IExecutor.StoredBatchInfo[] _committedBatches, struct IExecutor.ProofInput _proof) internal
```

### _verifyProof

```solidity
function _verifyProof(uint256[] proofPublicInput, struct IExecutor.ProofInput _proof) internal view
```

### _getBatchProofPublicInput

```solidity
function _getBatchProofPublicInput(bytes32 _prevBatchCommitment, bytes32 _currentBatchCommitment) internal pure returns (uint256)
```

_Gets zk proof public input_

### revertBatches

```solidity
function revertBatches(uint256 _newLastBatch) external
```

Reverts unexecuted batches

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newLastBatch | uint256 | batch number after which batches should be reverted NOTE: Doesn't delete the stored data about batches, but only decreases counters that are responsible for the number of batches |

### revertBatchesSharedBridge

```solidity
function revertBatchesSharedBridge(uint256, uint256 _newLastBatch) external
```

same as `revertBatches` but with the chainId so ValidatorTimelock can sort the inputs.

### _revertBatches

```solidity
function _revertBatches(uint256 _newLastBatch) internal
```

### _createBatchCommitment

```solidity
function _createBatchCommitment(struct IExecutor.CommitBatchInfo _newBatchData, bytes32 _stateDiffHash, bytes32[] _blobCommitments, bytes32[] _blobHashes) internal view returns (bytes32)
```

_Creates batch commitment from its data_

### _batchPassThroughData

```solidity
function _batchPassThroughData(struct IExecutor.CommitBatchInfo _batch) internal pure returns (bytes)
```

### _batchMetaParameters

```solidity
function _batchMetaParameters() internal view returns (bytes)
```

### _batchAuxiliaryOutput

```solidity
function _batchAuxiliaryOutput(struct IExecutor.CommitBatchInfo _batch, bytes32 _stateDiffHash, bytes32[] _blobCommitments, bytes32[] _blobHashes) internal pure returns (bytes)
```

### _encodeBlobAuxiliaryOutput

```solidity
function _encodeBlobAuxiliaryOutput(bytes32[] _blobCommitments, bytes32[] _blobHashes) internal pure returns (bytes32[] blobAuxOutputWords)
```

_Encodes the commitment to blobs to be used in the auxiliary output of the batch commitment_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _blobCommitments | bytes32[] | - the commitments to the blobs |
| _blobHashes | bytes32[] | - the hashes of the blobs |

### _hashStoredBatchInfo

```solidity
function _hashStoredBatchInfo(struct IExecutor.StoredBatchInfo _storedBatchInfo) internal pure returns (bytes32)
```

Returns the keccak hash of the ABI-encoded StoredBatchInfo

### _checkBit

```solidity
function _checkBit(uint256 _bitMap, uint8 _index) internal pure returns (bool)
```

Returns true if the bit at index {_index} is 1

### _setBit

```solidity
function _setBit(uint256 _bitMap, uint8 _index) internal pure returns (uint256)
```

Sets the given bit in {_num} at index {_index} to 1.

### _pointEvaluationPrecompile

```solidity
function _pointEvaluationPrecompile(bytes32 _versionedHash, bytes32 _openingPoint, bytes _openingValueCommitmentProof) internal view
```

Calls the point evaluation precompile and verifies the output
Verify p(z) = y given commitment that corresponds to the polynomial p(x) and a KZG proof.
Also verify that the provided commitment matches the provided versioned_hash.

### _verifyBlobInformation

```solidity
function _verifyBlobInformation(bytes _pubdataCommitments, bytes32[] _blobHashes) internal view returns (bytes32[] blobCommitments)
```

_Verifies that the blobs contain the correct data by calling the point evaluation precompile. For the precompile we need:
versioned hash || opening point || opening value || commitment || proof
the _pubdataCommitments will contain the last 4 values, the versioned hash is pulled from the BLOBHASH opcode
pubdataCommitments is a list of: opening point (16 bytes) || claimed value (32 bytes) || commitment (48 bytes) || proof (48 bytes)) = 144 bytes_

### _getBlobVersionedHash

```solidity
function _getBlobVersionedHash(uint256 _index) internal view virtual returns (bytes32 versionedHash)
```

