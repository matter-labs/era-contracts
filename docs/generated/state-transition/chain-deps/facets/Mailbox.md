## MailboxFacet

### getName

```solidity
string getName
```

| Name | Type | Description |
| ---- | ---- | ----------- |

### ERA_CHAIN_ID

```solidity
uint256 ERA_CHAIN_ID
```

_Era's chainID_

### constructor

```solidity
constructor(uint256 _eraChainId) public
```

### transferEthToSharedBridge

```solidity
function transferEthToSharedBridge() external
```

transfer Eth to shared bridge as part of migration process

### bridgehubRequestL2Transaction

```solidity
function bridgehubRequestL2Transaction(struct BridgehubL2TransactionRequest _request) external returns (bytes32 canonicalTxHash)
```

when requesting transactions through the bridgehub

### proveL2MessageInclusion

```solidity
function proveL2MessageInclusion(uint256 _batchNumber, uint256 _index, struct L2Message _message, bytes32[] _proof) public view returns (bool)
```

Prove that a specific arbitrary-length message was sent in a specific L2 batch number

| Name | Type | Description |
| ---- | ---- | ----------- |
| _batchNumber | uint256 | The executed L2 batch number in which the message appeared |
| _index | uint256 | The position in the L2 logs Merkle tree of the l2Log that was sent with the message |
| _message | struct L2Message | Information about the sent message: sender address, the message itself, tx index in the L2 batch where the message was sent |
| _proof | bytes32[] | Merkle proof for inclusion of L2 log that was sent with the message |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether the proof is valid |

### proveL2LogInclusion

```solidity
function proveL2LogInclusion(uint256 _batchNumber, uint256 _index, struct L2Log _log, bytes32[] _proof) external view returns (bool)
```

Prove that a specific L2 log was sent in a specific L2 batch

| Name | Type | Description |
| ---- | ---- | ----------- |
| _batchNumber | uint256 | The executed L2 batch number in which the log appeared |
| _index | uint256 | The position of the l2log in the L2 logs Merkle tree |
| _log | struct L2Log | Information about the sent log |
| _proof | bytes32[] | Merkle proof for inclusion of the L2 log |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether the proof is correct and L2 log is included in batch |

### proveL1ToL2TransactionStatus

```solidity
function proveL1ToL2TransactionStatus(bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof, enum TxStatus _status) public view returns (bool)
```

Prove that the L1 -> L2 transaction was processed with the specified status.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _l2TxHash | bytes32 | The L2 canonical transaction hash |
| _l2BatchNumber | uint256 | The L2 batch number where the transaction was processed |
| _l2MessageIndex | uint256 | The position in the L2 logs Merkle tree of the l2Log that was sent with the message |
| _l2TxNumberInBatch | uint16 | The L2 transaction number in the batch, in which the log was sent |
| _merkleProof | bytes32[] | The Merkle proof of the processing L1 -> L2 transaction |
| _status | enum TxStatus | The execution status of the L1 -> L2 transaction (true - success & 0 - fail) |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether the proof is correct and the transaction was actually executed with provided status NOTE: It may return `false` for incorrect proof, but it doesn't mean that the L1 -> L2 transaction has an opposite status! |

### _proveL2LogInclusion

```solidity
function _proveL2LogInclusion(uint256 _batchNumber, uint256 _index, struct L2Log _log, bytes32[] _proof) internal view returns (bool)
```

_Prove that a specific L2 log was sent in a specific L2 batch number_

### _L2MessageToLog

```solidity
function _L2MessageToLog(struct L2Message _message) internal pure returns (struct L2Log)
```

_Convert arbitrary-length message to the raw l2 log_

### l2TransactionBaseCost

```solidity
function l2TransactionBaseCost(uint256 _gasPrice, uint256 _l2GasLimit, uint256 _l2GasPerPubdataByteLimit) public view returns (uint256)
```

Estimates the cost in Ether of requesting execution of an L2 transaction from L1

| Name | Type | Description |
| ---- | ---- | ----------- |
| _gasPrice | uint256 | expected L1 gas price at which the user requests the transaction execution |
| _l2GasLimit | uint256 | Maximum amount of L2 gas that transaction can consume during execution on L2 |
| _l2GasPerPubdataByteLimit | uint256 | The maximum amount of L2 gas that the operator may charge the user for a single byte of pubdata. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The estimated ETH spent on L2 gas for the transaction |

### _deriveL2GasPrice

```solidity
function _deriveL2GasPrice(uint256 _l1GasPrice, uint256 _gasPerPubdata) internal view returns (uint256)
```

Derives the price for L2 gas in base token to be paid.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _l1GasPrice | uint256 | The gas price on L1 |
| _gasPerPubdata | uint256 | The price for each pubdata byte in L2 gas |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | uint256 | The price of L2 gas in the base token |

### finalizeEthWithdrawal

```solidity
function finalizeEthWithdrawal(uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes _message, bytes32[] _merkleProof) external
```

Finalize the withdrawal and release funds

| Name | Type | Description |
| ---- | ---- | ----------- |
| _l2BatchNumber | uint256 | The L2 batch number where the withdrawal was processed |
| _l2MessageIndex | uint256 | The position in the L2 logs Merkle tree of the l2Log that was sent with the message |
| _l2TxNumberInBatch | uint16 | The L2 transaction number in a batch, in which the log was sent |
| _message | bytes | The L2 withdraw data, stored in an L2 -> L1 message |
| _merkleProof | bytes32[] | The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization |

### requestL2Transaction

```solidity
function requestL2Transaction(address _contractL2, uint256 _l2Value, bytes _calldata, uint256 _l2GasLimit, uint256 _l2GasPerPubdataByteLimit, bytes[] _factoryDeps, address _refundRecipient) external payable returns (bytes32 canonicalTxHash)
```

@inheritdoc IMailbox

### _requestL2TransactionSender

```solidity
function _requestL2TransactionSender(struct BridgehubL2TransactionRequest _request) internal returns (bytes32 canonicalTxHash)
```

### _requestL2Transaction

```solidity
function _requestL2Transaction(struct WritePriorityOpParams _params) internal returns (bytes32 canonicalTxHash)
```

### _serializeL2Transaction

```solidity
function _serializeL2Transaction(struct WritePriorityOpParams _priorityOpParams) internal pure returns (struct L2CanonicalTransaction transaction)
```

### _writePriorityOp

```solidity
function _writePriorityOp(struct WritePriorityOpParams _priorityOpParams) internal returns (bytes32 canonicalTxHash)
```

Stores a transaction record in storage & send event about that

### _hashFactoryDeps

```solidity
function _hashFactoryDeps(bytes[] _factoryDeps) internal pure returns (uint256[] hashedFactoryDeps)
```

Hashes the L2 bytecodes and returns them in the format in which they are processed by the bootloader

