## InitializeData

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct InitializeData {
  uint256 chainId;
  address bridgehub;
  address stateTransitionManager;
  uint256 protocolVersion;
  address admin;
  address validatorTimelock;
  address baseToken;
  address baseTokenBridge;
  bytes32 storedBatchZero;
  contract IVerifier verifier;
  struct VerifierParams verifierParams;
  bytes32 l2BootloaderBytecodeHash;
  bytes32 l2DefaultAccountBytecodeHash;
  uint256 priorityTxMaxGasLimit;
  struct FeeParams feeParams;
  address blobVersionedHashRetriever;
}
```
## InitializeDataNewChain

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct InitializeDataNewChain {
  contract IVerifier verifier;
  struct VerifierParams verifierParams;
  bytes32 l2BootloaderBytecodeHash;
  bytes32 l2DefaultAccountBytecodeHash;
  uint256 priorityTxMaxGasLimit;
  struct FeeParams feeParams;
  address blobVersionedHashRetriever;
}
```
## IDiamondInit

### initialize

```solidity
function initialize(struct InitializeData _initData) external returns (bytes32)
```

