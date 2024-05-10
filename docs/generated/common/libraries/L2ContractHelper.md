## L2ContractHelper

Helper library for working with L2 contracts on L1.

### hashL2Bytecode

```solidity
function hashL2Bytecode(bytes _bytecode) internal pure returns (bytes32 hashedBytecode)
```

Validate the bytecode format and calculate its hash.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _bytecode | bytes | The bytecode to hash. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| hashedBytecode | bytes32 | The 32-byte hash of the bytecode. Note: The function reverts the execution if the bytecode has non expected format: - Bytecode bytes length is not a multiple of 32 - Bytecode bytes length is not less than 2^21 bytes (2^16 words) - Bytecode words length is not odd |

### validateBytecodeHash

```solidity
function validateBytecodeHash(bytes32 _bytecodeHash) internal pure
```

Validates the format of the given bytecode hash.

_Due to the specification of the L2 bytecode hash, not every 32 bytes could be a legit bytecode hash.
The function reverts on invalid bytecode hash format._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _bytecodeHash | bytes32 | The hash of the bytecode to validate. |

### bytecodeLen

```solidity
function bytecodeLen(bytes32 _bytecodeHash) internal pure returns (uint256 codeLengthInWords)
```

Returns the length of the bytecode associated with the given hash.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _bytecodeHash | bytes32 | The hash of the bytecode. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| codeLengthInWords | uint256 | The length of the bytecode in words. |

### computeCreate2Address

```solidity
function computeCreate2Address(address _sender, bytes32 _salt, bytes32 _bytecodeHash, bytes32 _constructorInputHash) internal pure returns (address)
```

Computes the create2 address for a Layer 2 contract.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _sender | address | The address of the sender. |
| _salt | bytes32 | The salt value to use in the create2 address computation. |
| _bytecodeHash | bytes32 | The contract bytecode hash. |
| _constructorInputHash | bytes32 | The hash of the constructor input data. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | address | The create2 address of the contract. NOTE: L2 create2 derivation is different from L1 derivation! |

