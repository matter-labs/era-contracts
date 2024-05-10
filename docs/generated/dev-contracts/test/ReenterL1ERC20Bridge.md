## ReenterL1ERC20Bridge

### test

```solidity
function test() internal virtual
```

### l1Erc20Bridge

```solidity
contract IL1ERC20Bridge l1Erc20Bridge
```

### FunctionToCall

```solidity
enum FunctionToCall {
  Unset,
  LegacyDeposit,
  Deposit,
  ClaimFailedDeposit,
  FinalizeWithdrawal
}
```

### functionToCall

```solidity
enum ReenterL1ERC20Bridge.FunctionToCall functionToCall
```

### setBridge

```solidity
function setBridge(contract IL1ERC20Bridge _l1Erc20Bridge) external
```

### setFunctionToCall

```solidity
function setFunctionToCall(enum ReenterL1ERC20Bridge.FunctionToCall _functionToCall) external
```

### fallback

```solidity
fallback() external payable
```

### receive

```solidity
receive() external payable
```

