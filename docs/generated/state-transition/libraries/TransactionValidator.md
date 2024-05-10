## TransactionValidator

### validateL1ToL2Transaction

```solidity
function validateL1ToL2Transaction(struct L2CanonicalTransaction _transaction, bytes _encoded, uint256 _priorityTxMaxGasLimit, uint256 _priorityTxMaxPubdata) internal pure
```

_Used to validate key properties of an L1->L2 transaction_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _transaction | struct L2CanonicalTransaction | The transaction to validate |
| _encoded | bytes | The abi encoded bytes of the transaction |
| _priorityTxMaxGasLimit | uint256 | The max gas limit, generally provided from Storage.sol |
| _priorityTxMaxPubdata | uint256 | The maximal amount of pubdata that a single L1->L2 transaction can emit |

### validateUpgradeTransaction

```solidity
function validateUpgradeTransaction(struct L2CanonicalTransaction _transaction) internal pure
```

_Used to validate upgrade transactions_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _transaction | struct L2CanonicalTransaction | The transaction to validate |

### getMinimalPriorityTransactionGasLimit

```solidity
function getMinimalPriorityTransactionGasLimit(uint256 _encodingLength, uint256 _numberOfFactoryDependencies, uint256 _l2GasPricePerPubdata) internal pure returns (uint256)
```

_Calculates the approximate minimum gas limit required for executing a priority transaction._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _encodingLength | uint256 | The length of the priority transaction encoding in bytes. |
| _numberOfFactoryDependencies | uint256 | The number of new factory dependencies that will be added. |
| _l2GasPricePerPubdata | uint256 | The L2 gas price for publishing the priority transaction on L2. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The minimum gas limit required to execute the priority transaction. Note: The calculation includes the main cost of the priority transaction, however, in reality, the operator can spend a little more gas on overheads. |

### getTransactionBodyGasLimit

```solidity
function getTransactionBodyGasLimit(uint256 _totalGasLimit, uint256 _encodingLength) internal pure returns (uint256 txBodyGasLimit)
```

Based on the full L2 gas limit (that includes the batch overhead) and other
properties of the transaction, returns the l2GasLimit for the body of the transaction (the actual execution).

| Name | Type | Description |
| ---- | ---- | ----------- |
| _totalGasLimit | uint256 | The L2 gas limit that includes both the overhead for processing the batch and the L2 gas needed to process the transaction itself (i.e. the actual l2GasLimit that will be used for the transaction). |
| _encodingLength | uint256 | The length of the ABI-encoding of the transaction. |

### getOverheadForTransaction

```solidity
function getOverheadForTransaction(uint256 _encodingLength) internal pure returns (uint256 batchOverheadForTransaction)
```

Based on the total L2 gas limit and several other parameters of the transaction
returns the part of the L2 gas that will be spent on the batch's overhead.

_The details of how this function works can be checked in the documentation
of the fee model of zkSync. The appropriate comments are also present
in the Rust implementation description of function `get_maximal_allowed_overhead`._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _encodingLength | uint256 | The length of the binary encoding of the transaction in bytes |

