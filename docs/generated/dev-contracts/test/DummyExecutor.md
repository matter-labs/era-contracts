## DummyExecutor

A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.

### test

```solidity
function test() internal virtual
```

### owner

```solidity
address owner
```

### shouldRevertOnCommitBatches

```solidity
bool shouldRevertOnCommitBatches
```

### shouldRevertOnProveBatches

```solidity
bool shouldRevertOnProveBatches
```

### shouldRevertOnExecuteBatches

```solidity
bool shouldRevertOnExecuteBatches
```

### getTotalBatchesCommitted

```solidity
uint256 getTotalBatchesCommitted
```

### getTotalBatchesVerified

```solidity
uint256 getTotalBatchesVerified
```

### getTotalBatchesExecuted

```solidity
uint256 getTotalBatchesExecuted
```

### getName

```solidity
string getName
```

| Name | Type | Description |
| ---- | ---- | ----------- |

### constructor

```solidity
constructor() public
```

Constructor sets the contract owner to the message sender

### onlyOwner

```solidity
modifier onlyOwner()
```

Modifier that only allows the owner to call certain functions

### getAdmin

```solidity
function getAdmin() external view returns (address)
```

### removePriorityQueueFront

```solidity
function removePriorityQueueFront(uint256 _index) external
```

Removing txs from the priority queue

### setShouldRevertOnCommitBatches

```solidity
function setShouldRevertOnCommitBatches(bool _shouldRevert) external
```

Allows the owner to set whether the contract should revert during commit blocks operation

### setShouldRevertOnProveBatches

```solidity
function setShouldRevertOnProveBatches(bool _shouldRevert) external
```

Allows the owner to set whether the contract should revert during prove batches operation

### setShouldRevertOnExecuteBatches

```solidity
function setShouldRevertOnExecuteBatches(bool _shouldRevert) external
```

Allows the owner to set whether the contract should revert during execute batches operation

### commitBatches

```solidity
function commitBatches(struct IExecutor.StoredBatchInfo _lastCommittedBatchData, struct IExecutor.CommitBatchInfo[] _newBatchesData) public
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

### proveBatches

```solidity
function proveBatches(struct IExecutor.StoredBatchInfo _prevBatch, struct IExecutor.StoredBatchInfo[] _committedBatches, struct IExecutor.ProofInput) public
```

### proveBatchesSharedBridge

```solidity
function proveBatchesSharedBridge(uint256, struct IExecutor.StoredBatchInfo _prevBatch, struct IExecutor.StoredBatchInfo[] _committedBatches, struct IExecutor.ProofInput _proof) external
```

### executeBatches

```solidity
function executeBatches(struct IExecutor.StoredBatchInfo[] _batchesData) public
```

The function called by the operator to finalize (execute) batches. It is responsible for:
- Processing all pending operations (commpleting priority requests).
- Finalizing this batch (i.e. allowing to withdraw funds from the system)

| Name | Type | Description |
| ---- | ---- | ----------- |
| _batchesData | struct IExecutor.StoredBatchInfo[] | Data of the batches to be executed. |

### executeBatchesSharedBridge

```solidity
function executeBatchesSharedBridge(uint256, struct IExecutor.StoredBatchInfo[] _batchesData) external
```

### revertBatches

```solidity
function revertBatches(uint256 _newLastBatch) public
```

Reverts unexecuted batches

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newLastBatch | uint256 | batch number after which batches should be reverted NOTE: Doesn't delete the stored data about batches, but only decreases counters that are responsible for the number of batches |

### revertBatchesSharedBridge

```solidity
function revertBatchesSharedBridge(uint256, uint256 _newLastBatch) external
```

### _maxU256

```solidity
function _maxU256(uint256 a, uint256 b) internal pure returns (uint256)
```

Returns larger of two values

