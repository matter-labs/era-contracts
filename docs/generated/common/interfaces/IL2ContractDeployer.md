## IL2ContractDeployer

System smart contract that is responsible for deploying other smart contracts on a zkSync hyperchain.

### ForceDeployment

A struct that describes a forced deployment on an address.

| Name | Type | Description |
| ---- | ---- | ----------- |

```solidity
struct ForceDeployment {
  bytes32 bytecodeHash;
  address newAddress;
  bool callConstructor;
  uint256 value;
  bytes input;
}
```

### forceDeployOnAddresses

```solidity
function forceDeployOnAddresses(struct IL2ContractDeployer.ForceDeployment[] _deployParams) external
```

This method is to be used only during an upgrade to set bytecodes on specific addresses.

### create2

```solidity
function create2(bytes32 _salt, bytes32 _bytecodeHash, bytes _input) external
```

Deploys a contract with similar address derivation rules to the EVM's `CREATE2` opcode.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _salt | bytes32 | The create2 salt. |
| _bytecodeHash | bytes32 | The correctly formatted hash of the bytecode. |
| _input | bytes | The constructor calldata. |

