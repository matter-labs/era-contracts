## SingletonFactory

Exposes CREATE2 (EIP-1014) to deploy bytecode on deterministic addresses based on initialization code
and salt.

### test

```solidity
function test() internal virtual
```

### deploy

```solidity
function deploy(bytes _initCode, bytes32 _salt) public returns (address payable createdContract)
```

Deploys `_initCode` using `_salt` for defining the deterministic address.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _initCode | bytes | Initialization code. |
| _salt | bytes32 | Arbitrary value to modify resulting address. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| createdContract | address payable | Created contract address. |

