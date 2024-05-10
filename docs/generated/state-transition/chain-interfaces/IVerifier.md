## VerifierParams

Part of the configuration parameters of ZKP circuits

```solidity
struct VerifierParams {
  bytes32 recursionNodeLevelVkHash;
  bytes32 recursionLeafLevelVkHash;
  bytes32 recursionCircuitsSetVksHash;
}
```
## IVerifier

### verify

```solidity
function verify(uint256[] _publicInputs, uint256[] _proof, uint256[] _recursiveAggregationInput) external view returns (bool)
```

_Verifies a zk-SNARK proof._

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | A boolean value indicating whether the zk-SNARK proof is valid. Note: The function may revert execution instead of returning false in some cases. |

### verificationKeyHash

```solidity
function verificationKeyHash() external pure returns (bytes32)
```

Calculates a keccak256 hash of the runtime loaded verification keys.

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32 | vkHash The keccak256 hash of the loaded verification keys. |

