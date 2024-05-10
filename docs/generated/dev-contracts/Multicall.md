## Multicall

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

### aggregate

```solidity
function aggregate(struct Multicall.Call[] calls) public returns (uint256 blockNumber, bytes[] returnData)
```

### getEthBalance

```solidity
function getEthBalance(address addr) public view returns (uint256 balance)
```

### getBlockHash

```solidity
function getBlockHash(uint256 blockNumber) public view returns (bytes32 blockHash)
```

### getLastBlockHash

```solidity
function getLastBlockHash() public view returns (bytes32 blockHash)
```

### getCurrentBlockTimestamp

```solidity
function getCurrentBlockTimestamp() public view returns (uint256 timestamp)
```

### getCurrentBlockDifficulty

```solidity
function getCurrentBlockDifficulty() public view returns (uint256 difficulty)
```

### getCurrentBlockGasLimit

```solidity
function getCurrentBlockGasLimit() public view returns (uint256 gaslimit)
```

### getCurrentBlockCoinbase

```solidity
function getCurrentBlockCoinbase() public view returns (address coinbase)
```

