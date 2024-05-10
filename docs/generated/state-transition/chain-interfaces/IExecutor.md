## SystemLogKey

_Enum used by L2 System Contracts to differentiate logs._

```solidity
enum SystemLogKey {
  L2_TO_L1_LOGS_TREE_ROOT_KEY,
  TOTAL_L2_TO_L1_PUBDATA_KEY,
  STATE_DIFF_HASH_KEY,
  PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
  PREV_BATCH_HASH_KEY,
  CHAINED_PRIORITY_TXN_HASH_KEY,
  NUMBER_OF_LAYER_1_TXS_KEY,
  BLOB_ONE_HASH_KEY,
  BLOB_TWO_HASH_KEY,
  BLOB_THREE_HASH_KEY,
  BLOB_FOUR_HASH_KEY,
  BLOB_FIVE_HASH_KEY,
  BLOB_SIX_HASH_KEY,
  EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY
}
```
## PubdataSource

_Enum used to determine the source of pubdata. At first we will support calldata and blobs but this can be extended._

```solidity
enum PubdataSource {
  Calldata,
  Blob
}
```
## LogProcessingOutput

```solidity
struct LogProcessingOutput {
  uint256 numberOfLayer1Txs;
  bytes32 chainedPriorityTxsHash;
  bytes32 previousBatchHash;
  bytes32 pubdataHash;
  bytes32 stateDiffHash;
  bytes32 l2LogsTreeRoot;
  uint256 packedBatchAndL2BlockTimestamp;
  bytes32[] blobHashes;
}
```
## BLOB_SIZE_BYTES

```solidity
uint256 BLOB_SIZE_BYTES
```

## L2_LOG_ADDRESS_OFFSET

```solidity
uint256 L2_LOG_ADDRESS_OFFSET
```

## L2_LOG_KEY_OFFSET

```solidity
uint256 L2_LOG_KEY_OFFSET
```

## L2_LOG_VALUE_OFFSET

```solidity
uint256 L2_LOG_VALUE_OFFSET
```

## BLS_MODULUS

```solidity
uint256 BLS_MODULUS
```

## PUBDATA_COMMITMENT_SIZE

```solidity
uint256 PUBDATA_COMMITMENT_SIZE
```

## PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET

```solidity
uint256 PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET
```

## PUBDATA_COMMITMENT_COMMITMENT_OFFSET

```solidity
uint256 PUBDATA_COMMITMENT_COMMITMENT_OFFSET
```

## MAX_NUMBER_OF_BLOBS

```solidity
uint256 MAX_NUMBER_OF_BLOBS
```

## TOTAL_BLOBS_IN_COMMITMENT

```solidity
uint256 TOTAL_BLOBS_IN_COMMITMENT
```

## IExecutor

### StoredBatchInfo

Rollup batch stored data

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct StoredBatchInfo {
  uint64 batchNumber;
  bytes32 batchHash;
  uint64 indexRepeatedStorageChanges;
  uint256 numberOfLayer1Txs;
  bytes32 priorityOperationsHash;
  bytes32 l2LogsTreeRoot;
  uint256 timestamp;
  bytes32 commitment;
}
```

### CommitBatchInfo

Data needed to commit new batch

_pubdataCommitments format: This will always start with a 1 byte pubdataSource flag. Current allowed values are 0 (calldata) or 1 (blobs)
                            kzg: list of: opening point (16 bytes) || claimed value (32 bytes) || commitment (48 bytes) || proof (48 bytes) = 144 bytes
                            calldata: pubdataCommitments.length - 1 - 32 bytes of pubdata
                                      and 32 bytes appended to serve as the blob commitment part for the aux output part of the batch commitment
For 2 blobs we will be sending 288 bytes of calldata instead of the full amount for pubdata.
When using calldata, we only need to send one blob commitment since the max number of bytes in calldata fits in a single blob and we can pull the
    linear hash from the system logs_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct CommitBatchInfo {
  uint64 batchNumber;
  uint64 timestamp;
  uint64 indexRepeatedStorageChanges;
  bytes32 newStateRoot;
  uint256 numberOfLayer1Txs;
  bytes32 priorityOperationsHash;
  bytes32 bootloaderHeapInitialContentsHash;
  bytes32 eventsQueueStateHash;
  bytes systemLogs;
  bytes pubdataCommitments;
}
```

### ProofInput

Recursive proof input data (individual commitments are constructed onchain)

```solidity
struct ProofInput {
  uint256[] recursiveAggregationInput;
  uint256[] serializedProof;
}
```

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
function commitBatchesSharedBridge(uint256 _chainId, struct IExecutor.StoredBatchInfo _lastCommittedBatchData, struct IExecutor.CommitBatchInfo[] _newBatchesData) external
```

same as `commitBatches` but with the chainId so ValidatorTimelock can sort the inputs.

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
function proveBatchesSharedBridge(uint256 _chainId, struct IExecutor.StoredBatchInfo _prevBatch, struct IExecutor.StoredBatchInfo[] _committedBatches, struct IExecutor.ProofInput _proof) external
```

same as `proveBatches` but with the chainId so ValidatorTimelock can sort the inputs.

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

### executeBatchesSharedBridge

```solidity
function executeBatchesSharedBridge(uint256 _chainId, struct IExecutor.StoredBatchInfo[] _batchesData) external
```

same as `executeBatches` but with the chainId so ValidatorTimelock can sort the inputs.

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
function revertBatchesSharedBridge(uint256 _chainId, uint256 _newLastBatch) external
```

same as `revertBatches` but with the chainId so ValidatorTimelock can sort the inputs.

### BlockCommit

```solidity
event BlockCommit(uint256 batchNumber, bytes32 batchHash, bytes32 commitment)
```

Event emitted when a batch is committed

_It has the name "BlockCommit" and not "BatchCommit" due to backward compatibility considerations_

| Name | Type | Description |
| ---- | ---- | ----------- |
| batchNumber | uint256 | Number of the batch committed |
| batchHash | bytes32 | Hash of the L2 batch |
| commitment | bytes32 | Calculated input for the zkSync circuit |

### BlocksVerification

```solidity
event BlocksVerification(uint256 previousLastVerifiedBatch, uint256 currentLastVerifiedBatch)
```

Event emitted when batches are verified

_It has the name "BlocksVerification" and not "BatchesVerification" due to backward compatibility considerations_

| Name | Type | Description |
| ---- | ---- | ----------- |
| previousLastVerifiedBatch | uint256 | Batch number of the previous last verified batch |
| currentLastVerifiedBatch | uint256 | Batch number of the current last verified batch |

### BlockExecution

```solidity
event BlockExecution(uint256 batchNumber, bytes32 batchHash, bytes32 commitment)
```

Event emitted when a batch is executed

_It has the name "BlockExecution" and not "BatchExecution" due to backward compatibility considerations_

| Name | Type | Description |
| ---- | ---- | ----------- |
| batchNumber | uint256 | Number of the batch executed |
| batchHash | bytes32 | Hash of the L2 batch |
| commitment | bytes32 | Verified input for the zkSync circuit |

### BlocksRevert

```solidity
event BlocksRevert(uint256 totalBatchesCommitted, uint256 totalBatchesVerified, uint256 totalBatchesExecuted)
```

Event emitted when batches are reverted

_It has the name "BlocksRevert" and not "BatchesRevert" due to backward compatibility considerations_

| Name | Type | Description |
| ---- | ---- | ----------- |
| totalBatchesCommitted | uint256 | Total number of committed batches after the revert |
| totalBatchesVerified | uint256 | Total number of verified batches after the revert |
| totalBatchesExecuted | uint256 | Total number of executed batches |

