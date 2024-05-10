## ILegacyGetters

_This interface contains getters for the zkSync contract that should not be used,
but still are kept for backward compatibility._

### getTotalBlocksCommitted

```solidity
function getTotalBlocksCommitted() external view returns (uint256)
```

_It is a *deprecated* method, please use `getTotalBatchesCommitted` instead_

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The total number of batches that were committed |

### getTotalBlocksVerified

```solidity
function getTotalBlocksVerified() external view returns (uint256)
```

_It is a *deprecated* method, please use `getTotalBatchesVerified` instead._

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The total number of batches that were committed & verified |

### getTotalBlocksExecuted

```solidity
function getTotalBlocksExecuted() external view returns (uint256)
```

_It is a *deprecated* method, please use `getTotalBatchesExecuted` instead._

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The total number of batches that were committed & verified & executed |

### storedBlockHash

```solidity
function storedBlockHash(uint256 _batchNumber) external view returns (bytes32)
```

For unfinalized (non executed) batches may change

_It is a *deprecated* method, please use `storedBatchHash` instead.
returns zero for non-committed batches_

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32 | The hash of committed L2 batch. |

### getL2SystemContractsUpgradeBlockNumber

```solidity
function getL2SystemContractsUpgradeBlockNumber() external view returns (uint256)
```

_It is a *deprecated* method, please use `getL2SystemContractsUpgradeBatchNumber` instead.
It is equal to 0 in the following two cases:
- No upgrade transaction has ever been processed.
- The upgrade transaction has been processed and the batch with such transaction has been
executed (i.e. finalized)._

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The L2 batch number in which the upgrade transaction was processed. |

