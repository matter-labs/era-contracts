## IL1SharedBridge

### LegacyDepositInitiated

```solidity
event LegacyDepositInitiated(uint256 chainId, bytes32 l2DepositTxHash, address from, address to, address l1Token, uint256 amount)
```

### BridgehubDepositInitiated

```solidity
event BridgehubDepositInitiated(uint256 chainId, bytes32 txDataHash, address from, address to, address l1Token, uint256 amount)
```

### BridgehubDepositBaseTokenInitiated

```solidity
event BridgehubDepositBaseTokenInitiated(uint256 chainId, address from, address l1Token, uint256 amount)
```

### BridgehubDepositFinalized

```solidity
event BridgehubDepositFinalized(uint256 chainId, bytes32 txDataHash, bytes32 l2DepositTxHash)
```

### WithdrawalFinalizedSharedBridge

```solidity
event WithdrawalFinalizedSharedBridge(uint256 chainId, address to, address l1Token, uint256 amount)
```

### ClaimedFailedDepositSharedBridge

```solidity
event ClaimedFailedDepositSharedBridge(uint256 chainId, address to, address l1Token, uint256 amount)
```

### isWithdrawalFinalized

```solidity
function isWithdrawalFinalized(uint256 _chainId, uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool)
```

### depositLegacyErc20Bridge

```solidity
function depositLegacyErc20Bridge(address _msgSender, address _l2Receiver, address _l1Token, uint256 _amount, uint256 _l2TxGasLimit, uint256 _l2TxGasPerPubdataByte, address _refundRecipient) external payable returns (bytes32 txHash)
```

### claimFailedDepositLegacyErc20Bridge

```solidity
function claimFailedDepositLegacyErc20Bridge(address _depositSender, address _l1Token, uint256 _amount, bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof) external
```

### claimFailedDeposit

```solidity
function claimFailedDeposit(uint256 _chainId, address _depositSender, address _l1Token, uint256 _amount, bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof) external
```

### finalizeWithdrawalLegacyErc20Bridge

```solidity
function finalizeWithdrawalLegacyErc20Bridge(uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes _message, bytes32[] _merkleProof) external returns (address l1Receiver, address l1Token, uint256 amount)
```

### finalizeWithdrawal

```solidity
function finalizeWithdrawal(uint256 _chainId, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes _message, bytes32[] _merkleProof) external
```

### setEraPostDiamondUpgradeFirstBatch

```solidity
function setEraPostDiamondUpgradeFirstBatch(uint256 _eraPostDiamondUpgradeFirstBatch) external
```

### setEraPostLegacyBridgeUpgradeFirstBatch

```solidity
function setEraPostLegacyBridgeUpgradeFirstBatch(uint256 _eraPostLegacyBridgeUpgradeFirstBatch) external
```

### setEraLegacyBridgeLastDepositTime

```solidity
function setEraLegacyBridgeLastDepositTime(uint256 _eraLegacyBridgeLastDepositBatch, uint256 _eraLegacyBridgeLastDepositTxNumber) external
```

### L1_WETH_TOKEN

```solidity
function L1_WETH_TOKEN() external view returns (address)
```

### BRIDGE_HUB

```solidity
function BRIDGE_HUB() external view returns (contract IBridgehub)
```

### legacyBridge

```solidity
function legacyBridge() external view returns (contract IL1ERC20Bridge)
```

### l2BridgeAddress

```solidity
function l2BridgeAddress(uint256 _chainId) external view returns (address)
```

### depositHappened

```solidity
function depositHappened(uint256 _chainId, bytes32 _l2TxHash) external view returns (bytes32)
```

### bridgehubDeposit

```solidity
function bridgehubDeposit(uint256 _chainId, address _prevMsgSender, uint256 _l2Value, bytes _data) external payable returns (struct L2TransactionRequestTwoBridgesInner request)
```

data is abi encoded :
address _l1Token,
uint256 _amount,
address _l2Receiver

### bridgehubDepositBaseToken

```solidity
function bridgehubDepositBaseToken(uint256 _chainId, address _prevMsgSender, address _l1Token, uint256 _amount) external payable
```

### bridgehubConfirmL2Transaction

```solidity
function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external
```

### receiveEth

```solidity
function receiveEth(uint256 _chainId) external payable
```

