## Multicall3

Aggregate results from multiple function calls

_Multicall & Multicall2 backwards-compatible
Aggregate methods are marked `payable` to save 24 gas per call_

### test

```solidity
function test() internal virtual
```

### Call

```solidity
struct Call {
  address target;
  bytes callData;
}
```

### Call3

```solidity
struct Call3 {
  address target;
  bool allowFailure;
  bytes callData;
}
```

### Call3Value

```solidity
struct Call3Value {
  address target;
  bool allowFailure;
  uint256 value;
  bytes callData;
}
```

### Result

```solidity
struct Result {
  bool success;
  bytes returnData;
}
```

### aggregate

```solidity
function aggregate(struct Multicall3.Call[] calls) public payable returns (uint256 blockNumber, bytes[] returnData)
```

Backwards-compatible call aggregation with Multicall

| Name | Type | Description |
| ---- | ---- | ----------- |
| calls | struct Multicall3.Call[] | An array of Call structs |

| Name | Type | Description |
| ---- | ---- | ----------- |
| blockNumber | uint256 | The block number where the calls were executed |
| returnData | bytes[] | An array of bytes containing the responses |

### tryAggregate

```solidity
function tryAggregate(bool requireSuccess, struct Multicall3.Call[] calls) public payable returns (struct Multicall3.Result[] returnData)
```

Backwards-compatible with Multicall2
Aggregate calls without requiring success

| Name | Type | Description |
| ---- | ---- | ----------- |
| requireSuccess | bool | If true, require all calls to succeed |
| calls | struct Multicall3.Call[] | An array of Call structs |

| Name | Type | Description |
| ---- | ---- | ----------- |
| returnData | struct Multicall3.Result[] | An array of Result structs |

### tryBlockAndAggregate

```solidity
function tryBlockAndAggregate(bool requireSuccess, struct Multicall3.Call[] calls) public payable returns (uint256 blockNumber, bytes32 blockHash, struct Multicall3.Result[] returnData)
```

Backwards-compatible with Multicall2
Aggregate calls and allow failures using tryAggregate

| Name | Type | Description |
| ---- | ---- | ----------- |
| requireSuccess | bool |  |
| calls | struct Multicall3.Call[] | An array of Call structs |

| Name | Type | Description |
| ---- | ---- | ----------- |
| blockNumber | uint256 | The block number where the calls were executed |
| blockHash | bytes32 | The hash of the block where the calls were executed |
| returnData | struct Multicall3.Result[] | An array of Result structs |

### blockAndAggregate

```solidity
function blockAndAggregate(struct Multicall3.Call[] calls) public payable returns (uint256 blockNumber, bytes32 blockHash, struct Multicall3.Result[] returnData)
```

Backwards-compatible with Multicall2
Aggregate calls and allow failures using tryAggregate

| Name | Type | Description |
| ---- | ---- | ----------- |
| calls | struct Multicall3.Call[] | An array of Call structs |

| Name | Type | Description |
| ---- | ---- | ----------- |
| blockNumber | uint256 | The block number where the calls were executed |
| blockHash | bytes32 | The hash of the block where the calls were executed |
| returnData | struct Multicall3.Result[] | An array of Result structs |

### aggregate3

```solidity
function aggregate3(struct Multicall3.Call3[] calls) public payable returns (struct Multicall3.Result[] returnData)
```

Aggregate calls, ensuring each returns success if required

| Name | Type | Description |
| ---- | ---- | ----------- |
| calls | struct Multicall3.Call3[] | An array of Call3 structs |

| Name | Type | Description |
| ---- | ---- | ----------- |
| returnData | struct Multicall3.Result[] | An array of Result structs |

### aggregate3Value

```solidity
function aggregate3Value(struct Multicall3.Call3Value[] calls) public payable returns (struct Multicall3.Result[] returnData)
```

Aggregate calls with a msg value
Reverts if msg.value is less than the sum of the call values

| Name | Type | Description |
| ---- | ---- | ----------- |
| calls | struct Multicall3.Call3Value[] | An array of Call3Value structs |

| Name | Type | Description |
| ---- | ---- | ----------- |
| returnData | struct Multicall3.Result[] | An array of Result structs |

### getBlockHash

```solidity
function getBlockHash(uint256 blockNumber) public view returns (bytes32 blockHash)
```

Returns the block hash for the given block number

| Name | Type | Description |
| ---- | ---- | ----------- |
| blockNumber | uint256 | The block number |

### getBlockNumber

```solidity
function getBlockNumber() public view returns (uint256 blockNumber)
```

Returns the block number

### getCurrentBlockCoinbase

```solidity
function getCurrentBlockCoinbase() public view returns (address coinbase)
```

Returns the block coinbase

### getCurrentBlockDifficulty

```solidity
function getCurrentBlockDifficulty() public view returns (uint256 difficulty)
```

Returns the block difficulty

### getCurrentBlockGasLimit

```solidity
function getCurrentBlockGasLimit() public view returns (uint256 gaslimit)
```

Returns the block gas limit

### getCurrentBlockTimestamp

```solidity
function getCurrentBlockTimestamp() public view returns (uint256 timestamp)
```

Returns the block timestamp

### getEthBalance

```solidity
function getEthBalance(address addr) public view returns (uint256 balance)
```

Returns the (ETH) balance of a given address

### getLastBlockHash

```solidity
function getLastBlockHash() public view returns (bytes32 blockHash)
```

Returns the block hash of the last block

### getBasefee

```solidity
function getBasefee() public view returns (uint256 basefee)
```

Gets the base fee of the given block
Can revert if the BASEFEE opcode is not implemented by the given chain

### getChainId

```solidity
function getChainId() public view returns (uint256 chainid)
```

Returns the chain id

