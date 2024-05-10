## L2TransactionRequestDirect

```solidity
struct L2TransactionRequestDirect {
  uint256 chainId;
  uint256 mintValue;
  address l2Contract;
  uint256 l2Value;
  bytes l2Calldata;
  uint256 l2GasLimit;
  uint256 l2GasPerPubdataByteLimit;
  bytes[] factoryDeps;
  address refundRecipient;
}
```
## L2TransactionRequestTwoBridgesOuter

```solidity
struct L2TransactionRequestTwoBridgesOuter {
  uint256 chainId;
  uint256 mintValue;
  uint256 l2Value;
  uint256 l2GasLimit;
  uint256 l2GasPerPubdataByteLimit;
  address refundRecipient;
  address secondBridgeAddress;
  uint256 secondBridgeValue;
  bytes secondBridgeCalldata;
}
```
## L2TransactionRequestTwoBridgesInner

```solidity
struct L2TransactionRequestTwoBridgesInner {
  bytes32 magicValue;
  address l2Contract;
  bytes l2Calldata;
  bytes[] factoryDeps;
  bytes32 txDataHash;
}
```
## IBridgehub

### NewPendingAdmin

```solidity
event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin)
```

pendingAdmin is changed

_Also emitted when new admin is accepted and in this case, `newPendingAdmin` would be zero address_

### NewAdmin

```solidity
event NewAdmin(address oldAdmin, address newAdmin)
```

Admin changed

### setPendingAdmin

```solidity
function setPendingAdmin(address _newPendingAdmin) external
```

Starts the transfer of admin rights. Only the current admin can propose a new pending one.
New admin can accept admin rights by calling `acceptAdmin` function.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _newPendingAdmin | address | Address of the new admin |

### acceptAdmin

```solidity
function acceptAdmin() external
```

Accepts transfer of admin rights. Only pending admin can accept the role.

### stateTransitionManagerIsRegistered

```solidity
function stateTransitionManagerIsRegistered(address _stateTransitionManager) external view returns (bool)
```

Getters

### stateTransitionManager

```solidity
function stateTransitionManager(uint256 _chainId) external view returns (address)
```

### tokenIsRegistered

```solidity
function tokenIsRegistered(address _baseToken) external view returns (bool)
```

### baseToken

```solidity
function baseToken(uint256 _chainId) external view returns (address)
```

### sharedBridge

```solidity
function sharedBridge() external view returns (contract IL1SharedBridge)
```

### getHyperchain

```solidity
function getHyperchain(uint256 _chainId) external view returns (address)
```

### proveL2MessageInclusion

```solidity
function proveL2MessageInclusion(uint256 _chainId, uint256 _batchNumber, uint256 _index, struct L2Message _message, bytes32[] _proof) external view returns (bool)
```

Mailbox forwarder

### proveL2LogInclusion

```solidity
function proveL2LogInclusion(uint256 _chainId, uint256 _batchNumber, uint256 _index, struct L2Log _log, bytes32[] _proof) external view returns (bool)
```

### proveL1ToL2TransactionStatus

```solidity
function proveL1ToL2TransactionStatus(uint256 _chainId, bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof, enum TxStatus _status) external view returns (bool)
```

### requestL2TransactionDirect

```solidity
function requestL2TransactionDirect(struct L2TransactionRequestDirect _request) external payable returns (bytes32 canonicalTxHash)
```

### requestL2TransactionTwoBridges

```solidity
function requestL2TransactionTwoBridges(struct L2TransactionRequestTwoBridgesOuter _request) external payable returns (bytes32 canonicalTxHash)
```

### l2TransactionBaseCost

```solidity
function l2TransactionBaseCost(uint256 _chainId, uint256 _gasPrice, uint256 _l2GasLimit, uint256 _l2GasPerPubdataByteLimit) external view returns (uint256)
```

### createNewChain

```solidity
function createNewChain(uint256 _chainId, address _stateTransitionManager, address _baseToken, uint256 _salt, address _admin, bytes _initData) external returns (uint256 chainId)
```

### addStateTransitionManager

```solidity
function addStateTransitionManager(address _stateTransitionManager) external
```

### removeStateTransitionManager

```solidity
function removeStateTransitionManager(address _stateTransitionManager) external
```

### addToken

```solidity
function addToken(address _token) external
```

### setSharedBridge

```solidity
function setSharedBridge(address _sharedBridge) external
```

### NewChain

```solidity
event NewChain(uint256 chainId, address stateTransitionManager, address chainGovernance)
```

