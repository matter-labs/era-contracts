## LibMap

Library for storage of packed unsigned integers.

_This library is an adaptation of the corresponding Solady library (https://github.com/vectorized/solady/blob/main/src/utils/LibMap.sol)_

### Uint32Map

_A uint32 map in storage._

```solidity
struct Uint32Map {
  mapping(uint256 => uint256) map;
}
```

### get

```solidity
function get(struct LibMap.Uint32Map _map, uint256 _index) internal view returns (uint32 result)
```

_Retrieves the uint32 value at a specific index from the Uint32Map._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _map | struct LibMap.Uint32Map | The Uint32Map instance containing the packed uint32 values. |
| _index | uint256 | The index of the uint32 value to retrieve. |

| Name | Type | Description |
| ---- | ---- | ----------- |
| result | uint32 | The uint32 value at the specified index. |

### set

```solidity
function set(struct LibMap.Uint32Map _map, uint256 _index, uint32 _value) internal
```

_Updates the uint32 value at `_index` in `map`._

| Name | Type | Description |
| ---- | ---- | ----------- |
| _map | struct LibMap.Uint32Map | The Uint32Map instance containing the packed uint32 values. |
| _index | uint256 | The index of the uint32 value to set. |
| _value | uint32 | The new value at the specified index. |

