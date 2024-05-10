## DummyStateTransitionManagerForValidatorTimelock

A test smart contract implementing the IExecutor interface to simulate Executor behavior for testing purposes.

### test

```solidity
function test() internal virtual
```

### chainAdmin

```solidity
address chainAdmin
```

### hyperchainAddress

```solidity
address hyperchainAddress
```

### constructor

```solidity
constructor(address _chainAdmin, address _hyperchain) public
```

### getChainAdmin

```solidity
function getChainAdmin(uint256) external view returns (address)
```

### getHyperchain

```solidity
function getHyperchain(uint256) external view returns (address)
```

