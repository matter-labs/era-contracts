## GettersFacet

### getName

```solidity
string getName
```

| Name | Type | Description |
| ---- | ---- | ----------- |

### getVerifier

```solidity
function getVerifier() external view returns (address)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address of the verifier smart contract |

### getAdmin

```solidity
function getAdmin() external view returns (address)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address of the current admin |

### getPendingAdmin

```solidity
function getPendingAdmin() external view returns (address)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address of the pending admin |

### getBridgehub

```solidity
function getBridgehub() external view returns (address)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address of the bridgehub |

### getStateTransitionManager

```solidity
function getStateTransitionManager() external view returns (address)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address of the state transition |

### getBaseToken

```solidity
function getBaseToken() external view returns (address)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address of the base token |

### getBaseTokenBridge

```solidity
function getBaseTokenBridge() external view returns (address)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The address of the base token bridge |

### baseTokenGasPriceMultiplierNominator

```solidity
function baseTokenGasPriceMultiplierNominator() external view returns (uint128)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint128 | the baseTokenGasPriceMultiplierNominator, used to compare the baseTokenPrice to ether for L1->L2 transactions |

### baseTokenGasPriceMultiplierDenominator

```solidity
function baseTokenGasPriceMultiplierDenominator() external view returns (uint128)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint128 | the baseTokenGasPriceMultiplierDenominator, used to compare the baseTokenPrice to ether for L1->L2 transactions |

### getTotalBatchesCommitted

```solidity
function getTotalBatchesCommitted() external view returns (uint256)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The total number of batches that were committed |

### getTotalBatchesVerified

```solidity
function getTotalBatchesVerified() external view returns (uint256)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The total number of batches that were committed & verified |

### getTotalBatchesExecuted

```solidity
function getTotalBatchesExecuted() external view returns (uint256)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The total number of batches that were committed & verified & executed |

### getTotalPriorityTxs

```solidity
function getTotalPriorityTxs() external view returns (uint256)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The total number of priority operations that were added to the priority queue, including all processed ones |

### getFirstUnprocessedPriorityTx

```solidity
function getFirstUnprocessedPriorityTx() external view returns (uint256)
```

The function that returns the first unprocessed priority transaction.

_Returns zero if and only if no operations were processed from the queue.
If all the transactions were processed, it will return the last processed index, so
in case exactly *unprocessed* transactions are needed, one should check that getPriorityQueueSize() is greater than 0._

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | Index of the oldest priority operation that wasn't processed yet |

### getPriorityQueueSize

```solidity
function getPriorityQueueSize() external view returns (uint256)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The number of priority operations currently in the queue |

### priorityQueueFrontOperation

```solidity
function priorityQueueFrontOperation() external view returns (struct PriorityOperation)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct PriorityOperation | The first unprocessed priority operation from the queue |

### isValidator

```solidity
function isValidator(address _address) external view returns (bool)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether the address has a validator access |

### l2LogsRootHash

```solidity
function l2LogsRootHash(uint256 _batchNumber) external view returns (bytes32)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32 |  |

### storedBatchHash

```solidity
function storedBatchHash(uint256 _batchNumber) external view returns (bytes32)
```

For unfinalized (non executed) batches may change

_returns zero for non-committed batches_

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32 | The hash of committed L2 batch. |

### getL2BootloaderBytecodeHash

```solidity
function getL2BootloaderBytecodeHash() external view returns (bytes32)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32 | Bytecode hash of bootloader program. |

### getL2DefaultAccountBytecodeHash

```solidity
function getL2DefaultAccountBytecodeHash() external view returns (bytes32)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32 | Bytecode hash of default account (bytecode for EOA). |

### getVerifierParams

```solidity
function getVerifierParams() external view returns (struct VerifierParams)
```

_This function is deprecated and will soon be removed._

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | struct VerifierParams | Verifier parameters. |

### getProtocolVersion

```solidity
function getProtocolVersion() external view returns (uint256)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The current protocol version |

### getL2SystemContractsUpgradeTxHash

```solidity
function getL2SystemContractsUpgradeTxHash() external view returns (bytes32)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32 | The upgrade system contract transaction hash, 0 if the upgrade is not initialized |

### getL2SystemContractsUpgradeBatchNumber

```solidity
function getL2SystemContractsUpgradeBatchNumber() external view returns (uint256)
```

_It is equal to 0 in the following two cases:
- No upgrade transaction has ever been processed.
- The upgrade transaction has been processed and the batch with such transaction has been
executed (i.e. finalized)._

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The L2 batch number in which the upgrade transaction was processed. |

### isDiamondStorageFrozen

```solidity
function isDiamondStorageFrozen() external view returns (bool)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether the diamond is frozen or not |

### isFacetFreezable

```solidity
function isFacetFreezable(address _facet) external view returns (bool isFreezable)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| isFreezable | bool | Whether the facet can be frozen by the admin or always accessible |

### getPriorityTxMaxGasLimit

```solidity
function getPriorityTxMaxGasLimit() external view returns (uint256)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The maximum number of L2 gas that a user can request for L1 -> L2 transactions |

### isFunctionFreezable

```solidity
function isFunctionFreezable(bytes4 _selector) external view returns (bool)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether the selector can be frozen by the admin or always accessible |

### isEthWithdrawalFinalized

```solidity
function isEthWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| _l2BatchNumber | uint256 | The L2 batch number within which the withdrawal happened. |
| _l2MessageIndex | uint256 | The index of the L2->L1 message denoting the withdrawal. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether a withdrawal has been finalized. |

### getPubdataPricingMode

```solidity
function getPubdataPricingMode() external view returns (enum PubdataPricingMode)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | enum PubdataPricingMode | The pubdata pricing mode. |

### facets

```solidity
function facets() external view returns (struct IGetters.Facet[] result)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| result | struct IGetters.Facet[] | result All facet addresses and their function selectors |

### facetFunctionSelectors

```solidity
function facetFunctionSelectors(address _facet) external view returns (bytes4[])
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes4[] | NON-sorted array with function selectors supported by a specific facet |

### facetAddresses

```solidity
function facetAddresses() external view returns (address[])
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address[] |  |

### facetAddress

```solidity
function facetAddress(bytes4 _selector) external view returns (address)
```

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address |  |

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

