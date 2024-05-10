## DummySharedBridge

### BridgehubDepositBaseTokenInitiated

```solidity
event BridgehubDepositBaseTokenInitiated(uint256 chainId, address from, address l1Token, uint256 amount)
```

### dummyL2DepositTxHash

```solidity
bytes32 dummyL2DepositTxHash
```

### chainBalance

```solidity
mapping(uint256 => mapping(address => uint256)) chainBalance
```

_Maps token balances for each chain to prevent unauthorized spending across hyperchains.
This serves as a security measure until hyperbridging is implemented._

### hyperbridgingEnabled

```solidity
mapping(uint256 => bool) hyperbridgingEnabled
```

_Indicates whether the hyperbridging is enabled for a given chain._

### l1ReceiverReturnInFinalizeWithdrawal

```solidity
address l1ReceiverReturnInFinalizeWithdrawal
```

### l1TokenReturnInFinalizeWithdrawal

```solidity
address l1TokenReturnInFinalizeWithdrawal
```

### amountReturnInFinalizeWithdrawal

```solidity
uint256 amountReturnInFinalizeWithdrawal
```

### constructor

```solidity
constructor(bytes32 _dummyL2DepositTxHash) public
```

### setDataToBeReturnedInFinalizeWithdrawal

```solidity
function setDataToBeReturnedInFinalizeWithdrawal(address _l1Receiver, address _l1Token, uint256 _amount) external
```

### depositLegacyErc20Bridge

```solidity
function depositLegacyErc20Bridge(address, address, address, uint256, uint256, uint256, address) external payable returns (bytes32 txHash)
```

### claimFailedDepositLegacyErc20Bridge

```solidity
function claimFailedDepositLegacyErc20Bridge(address, address, uint256, bytes32, uint256, uint256, uint16, bytes32[]) external
```

### finalizeWithdrawalLegacyErc20Bridge

```solidity
function finalizeWithdrawalLegacyErc20Bridge(uint256, uint256, uint16, bytes, bytes32[]) external view returns (address l1Receiver, address l1Token, uint256 amount)
```

### Debugger

```solidity
event Debugger(uint256)
```

### bridgehubDepositBaseToken

```solidity
function bridgehubDepositBaseToken(uint256 _chainId, address _prevMsgSender, address _l1Token, uint256 _amount) external payable
```

### _depositFunds

```solidity
function _depositFunds(address _from, contract IERC20 _token, uint256 _amount) internal returns (uint256)
```

### bridgehubDeposit

```solidity
function bridgehubDeposit(uint256, address, uint256, bytes) external payable returns (struct L2TransactionRequestTwoBridgesInner request)
```

### bridgehubConfirmL2Transaction

```solidity
function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external
```

