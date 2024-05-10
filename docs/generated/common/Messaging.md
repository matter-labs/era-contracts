## TxStatus

_The enum that represents the transaction execution status_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
enum TxStatus {
  Failure,
  Success
}
```
## L2Log

_The log passed from L2_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct L2Log {
  uint8 l2ShardId;
  bool isService;
  uint16 txNumberInBatch;
  address sender;
  bytes32 key;
  bytes32 value;
}
```
## L2Message

Under the hood it is `L2Log` sent from the special system L2 contract

_An arbitrary length message passed from L2_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct L2Message {
  uint16 txNumberInBatch;
  address sender;
  bytes data;
}
```
## WritePriorityOpParams

_Internal structure that contains the parameters for the writePriorityOp
internal function._

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct WritePriorityOpParams {
  uint256 txId;
  uint256 l2GasPrice;
  uint64 expirationTimestamp;
  struct BridgehubL2TransactionRequest request;
}
```
## L2CanonicalTransaction

_Structure that includes all fields of the L2 transaction
The hash of this structure is the "canonical L2 transaction hash" and can
be used as a unique identifier of a tx_

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct L2CanonicalTransaction {
  uint256 txType;
  uint256 from;
  uint256 to;
  uint256 gasLimit;
  uint256 gasPerPubdataByteLimit;
  uint256 maxFeePerGas;
  uint256 maxPriorityFeePerGas;
  uint256 paymaster;
  uint256 nonce;
  uint256 value;
  uint256[4] reserved;
  bytes data;
  bytes signature;
  uint256[] factoryDeps;
  bytes paymasterInput;
  bytes reservedDynamic;
}
```
## BridgehubL2TransactionRequest

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct BridgehubL2TransactionRequest {
  address sender;
  address contractL2;
  uint256 mintValue;
  uint256 l2Value;
  bytes l2Calldata;
  uint256 l2GasLimit;
  uint256 l2GasPerPubdataByteLimit;
  bytes[] factoryDeps;
  address refundRecipient;
}
```
