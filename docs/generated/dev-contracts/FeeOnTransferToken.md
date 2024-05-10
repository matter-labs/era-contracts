## FeeOnTransferToken

### test

```solidity
function test() internal
```

### constructor

```solidity
constructor(string name_, string symbol_, uint8 decimals_) public
```

### _transfer

```solidity
function _transfer(address from, address to, uint256 amount) internal
```

_Moves `amount` of tokens from `from` to `to`.

This internal function is equivalent to {transfer}, and can be used to
e.g. implement automatic token fees, slashing mechanisms, etc.

Emits a {Transfer} event.

Requirements:

- `from` cannot be the zero address.
- `to` cannot be the zero address.
- `from` must have a balance of at least `amount`._

