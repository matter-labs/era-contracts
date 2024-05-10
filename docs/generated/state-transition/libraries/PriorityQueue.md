## PriorityOperation

The structure that contains meta information of the L2 transaction that was requested from L1

_The weird size of fields was selected specifically to minimize the structure storage size_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct PriorityOperation {
  bytes32 canonicalTxHash;
  uint64 expirationTimestamp;
  uint192 layer2Tip;
}
```
## PriorityQueue

_The library provides the API to interact with the priority queue container
Order of processing operations from queue - FIFO (Fist in - first out)_

### Queue

Container that stores priority operations

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct Queue {
  mapping(uint256 => struct PriorityOperation) data;
  uint256 tail;
  uint256 head;
}
```

### getFirstUnprocessedPriorityTx

```solidity
function getFirstUnprocessedPriorityTx(struct PriorityQueue.Queue _queue) internal view returns (uint256)
```

Returns zero if and only if no operations were processed from the queue

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | Index of the oldest priority operation that wasn't processed yet |

### getTotalPriorityTxs

```solidity
function getTotalPriorityTxs(struct PriorityQueue.Queue _queue) internal view returns (uint256)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The total number of priority operations that were added to the priority queue, including all processed ones |

### getSize

```solidity
function getSize(struct PriorityQueue.Queue _queue) internal view returns (uint256)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The total number of unprocessed priority operations in a priority queue |

### isEmpty

```solidity
function isEmpty(struct PriorityQueue.Queue _queue) internal view returns (bool)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether the priority queue contains no operations |

### pushBack

```solidity
function pushBack(struct PriorityQueue.Queue _queue, struct PriorityOperation _operation) internal
```

Add the priority operation to the end of the priority queue

### front

```solidity
function front(struct PriorityQueue.Queue _queue) internal view returns (struct PriorityOperation)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct PriorityOperation | The first unprocessed priority operation from the queue |

### popFront

```solidity
function popFront(struct PriorityQueue.Queue _queue) internal returns (struct PriorityOperation priorityOperation)
```

Remove the first unprocessed priority operation from the queue

| Name | Type | Description |
| ---- | ---- | ----------- |
| priorityOperation | struct PriorityOperation | that was popped from the priority queue |

