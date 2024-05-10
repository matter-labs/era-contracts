## IMailbox

### proveL2MessageInclusion

```solidity
function proveL2MessageInclusion(uint256 _batchNumber, uint256 _index, struct L2Message _message, bytes32[] _proof) external view returns (bool)
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
function proveL1ToL2TransactionStatus(bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof, enum TxStatus _status) external view returns (bool)
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

Request execution of L2 transaction from L1.

_If the L2 deposit finalization transaction fails, the `_refundRecipient` will receive the `_l2Value`.
Please note, the contract may change the refund recipient's address to eliminate sending funds to addresses out of control.
- If `_refundRecipient` is a contract on L1, the refund will be sent to the aliased `_refundRecipient`.
- If `_refundRecipient` is set to `address(0)` and the sender has NO deployed bytecode on L1, the refund will be sent to the `msg.sender` address.
- If `_refundRecipient` is set to `address(0)` and the sender has deployed bytecode on L1, the refund will be sent to the aliased `msg.sender` address.
The address aliasing of L1 contracts as refund recipient on L2 is necessary to guarantee that the funds are controllable,
since address aliasing to the from address for the L2 tx will be applied if the L1 `msg.sender` is a contract.
Without address aliasing for L1 contracts as refund recipients they would not be able to make proper L2 tx requests
through the Mailbox to use or withdraw the funds from L2, and the funds would be lost._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _contractL2 | address | The L2 receiver address |
| _l2Value | uint256 | `msg.value` of L2 transaction |
| _calldata | bytes | The input of the L2 transaction |
| _l2GasLimit | uint256 | Maximum amount of L2 gas that transaction can consume during execution on L2 |
| _l2GasPerPubdataByteLimit | uint256 | The maximum amount L2 gas that the operator may charge the user for single byte of pubdata. |
| _factoryDeps | bytes[] | An array of L2 bytecodes that will be marked as known on L2 |
| _refundRecipient | address | The address on L2 that will receive the refund for the transaction. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| canonicalTxHash | bytes32 | The hash of the requested L2 transaction. This hash can be used to follow the transaction status |

### bridgehubRequestL2Transaction

```solidity
function bridgehubRequestL2Transaction(struct BridgehubL2TransactionRequest _request) external returns (bytes32 canonicalTxHash)
```

### l2TransactionBaseCost

```solidity
function l2TransactionBaseCost(uint256 _gasPrice, uint256 _l2GasLimit, uint256 _l2GasPerPubdataByteLimit) external view returns (uint256)
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

### transferEthToSharedBridge

```solidity
function transferEthToSharedBridge() external
```

transfer Eth to shared bridge as part of migration process

### NewPriorityRequest

```solidity
event NewPriorityRequest(uint256 txId, bytes32 txHash, uint64 expirationTimestamp, struct L2CanonicalTransaction transaction, bytes[] factoryDeps)
```

New priority request event. Emitted when a request is placed into the priority queue

| Name | Type | Description |
| ---- | ---- | ----------- |
| txId | uint256 | Serial number of the priority operation |
| txHash | bytes32 | keccak256 hash of encoded transaction representation |
| expirationTimestamp | uint64 | Timestamp up to which priority request should be processed |
| transaction | struct L2CanonicalTransaction | The whole transaction structure that is requested to be executed on L2 |
| factoryDeps | bytes[] | An array of bytecodes that were shown in the L1 public data. Will be marked as known bytecodes in L2 |

