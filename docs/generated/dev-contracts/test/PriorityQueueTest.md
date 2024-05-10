## PriorityQueueTest

### priorityQueue

```solidity
struct PriorityQueue.Queue priorityQueue
```

### getFirstUnprocessedPriorityTx

```solidity
function getFirstUnprocessedPriorityTx() external view returns (uint256)
```

### getTotalPriorityTxs

```solidity
function getTotalPriorityTxs() external view returns (uint256)
```

### getSize

```solidity
function getSize() external view returns (uint256)
```

### isEmpty

```solidity
function isEmpty() external view returns (bool)
```

### pushBack

```solidity
function pushBack(struct PriorityOperation _operation) external
```

### front

```solidity
function front() external view returns (struct PriorityOperation)
```

### popFront

```solidity
function popFront() external returns (struct PriorityOperation operation)
```

