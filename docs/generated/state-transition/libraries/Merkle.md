## Merkle

### calculateRoot

```solidity
function calculateRoot(bytes32[] _path, uint256 _index, bytes32 _itemHash) internal pure returns (bytes32)
```

_Calculate Merkle root by the provided Merkle proof.
NOTE: When using this function, check that the _path length is equal to the tree height to prevent shorter/longer paths attack_

| Name | Type | Description |
| ---- | ---- | ----------- |
| _path | bytes32[] | Merkle path from the leaf to the root |
| _index | uint256 | Leaf index in the tree |
| _itemHash | bytes32 | Hash of leaf content |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bytes32 | The Merkle root |

