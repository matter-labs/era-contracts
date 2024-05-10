## ReenterGovernance

### test

```solidity
function test() internal virtual
```

### governance

```solidity
contract IGovernance governance
```

### call

```solidity
struct IGovernance.Call call
```

### predecessor

```solidity
bytes32 predecessor
```

### salt

```solidity
bytes32 salt
```

### alreadyReentered

```solidity
bool alreadyReentered
```

### FunctionToCall

```solidity
enum FunctionToCall {
  Unset,
  Execute,
  ExecuteInstant,
  Cancel
}
```

### functionToCall

```solidity
enum ReenterGovernance.FunctionToCall functionToCall
```

### initialize

```solidity
function initialize(contract IGovernance _governance, struct IGovernance.Operation _op, enum ReenterGovernance.FunctionToCall _functionToCall) external
```

### fallback

```solidity
fallback() external payable
```

