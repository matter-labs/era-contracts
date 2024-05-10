## IL1ERC20Bridge

Legacy Bridge interface before hyperchain migration, used for backward compatibility with zkSync Era

### DepositInitiated

```solidity
event DepositInitiated(bytes32 l2DepositTxHash, address from, address to, address l1Token, uint256 amount)
```

### WithdrawalFinalized

```solidity
event WithdrawalFinalized(address to, address l1Token, uint256 amount)
```

### ClaimedFailedDeposit

```solidity
event ClaimedFailedDeposit(address to, address l1Token, uint256 amount)
```

### isWithdrawalFinalized

```solidity
function isWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool)
```

### deposit

```solidity
function deposit(address _l2Receiver, address _l1Token, uint256 _amount, uint256 _l2TxGasLimit, uint256 _l2TxGasPerPubdataByte, address _refundRecipient) external payable returns (bytes32 txHash)
```

### deposit

```solidity
function deposit(address _l2Receiver, address _l1Token, uint256 _amount, uint256 _l2TxGasLimit, uint256 _l2TxGasPerPubdataByte) external payable returns (bytes32 txHash)
```

### claimFailedDeposit

```solidity
function claimFailedDeposit(address _depositSender, address _l1Token, bytes32 _l2TxHash, uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes32[] _merkleProof) external
```

### finalizeWithdrawal

```solidity
function finalizeWithdrawal(uint256 _l2BatchNumber, uint256 _l2MessageIndex, uint16 _l2TxNumberInBatch, bytes _message, bytes32[] _merkleProof) external
```

### l2TokenAddress

```solidity
function l2TokenAddress(address _l1Token) external view returns (address)
```

### SHARED_BRIDGE

```solidity
function SHARED_BRIDGE() external view returns (contract IL1SharedBridge)
```

### l2TokenBeacon

```solidity
function l2TokenBeacon() external view returns (address)
```

### l2Bridge

```solidity
function l2Bridge() external view returns (address)
```

### depositAmount

```solidity
function depositAmount(address _account, address _l1Token, bytes32 _depositL2TxHash) external returns (uint256 amount)
```

### transferTokenToSharedBridge

```solidity
function transferTokenToSharedBridge(address _token) external
```

