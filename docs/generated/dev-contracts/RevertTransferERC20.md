## RevertTransferERC20

_Used for testing failed ERC-20 withdrawals from the zkSync smart contract_

### test

```solidity
function test() internal
```

### revertTransfer

```solidity
bool revertTransfer
```

### constructor

```solidity
constructor(string name, string symbol, uint8 decimals) public
```

### setRevertTransfer

```solidity
function setRevertTransfer(bool newValue) public
```

### transfer

```solidity
function transfer(address recipient, uint256 amount) public virtual returns (bool)
```

