// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Library for storage of packed unsigned integers.
/// @author Matter Labs
/// @dev This library is an adaptation of the corresponding Solady library (https://github.com/vectorized/solady/blob/main/src/utils/LibMap.sol)
/// @custom:security-contact security@matterlabs.dev
library LibMap {
    /// @dev A uint32 map in storage.
    struct Uint32Map {
        mapping(uint256 packedIndex => uint256 eightPackedValues) map;
    }

    /// @dev Retrieves the uint32 value at a specific index from the Uint32Map.
    /// @param _map The Uint32Map instance containing the packed uint32 values.
    /// @param _index The index of the uint32 value to retrieve.
    /// @return result The uint32 value at the specified index.
    function get(Uint32Map storage _map, uint256 _index) internal view returns (uint32 result) {
        unchecked {
            // Each storage slot can store 256 bits of data.
            // As uint32 is 32 bits long, 8 uint32s can be packed into one storage slot.
            // Hence, `_index / 8` is done to find the storage slot that contains the required uint32.
            uint256 mapValue = _map.map[_index / 8];

            // First three bits of the original `_index` denotes the position of the uint32 in that slot.
            // So, '(_index & 7) * 32' is done to find the bit position of the uint32 in that storage slot.
            uint256 bitOffset = (_index & 7) * 32;

            // Shift the bits to the right and retrieve the uint32 value.
            result = uint32(mapValue >> bitOffset);
        }
    }

    /// @dev Updates the uint32 value at `_index` in `map`.
    /// @param _map The Uint32Map instance containing the packed uint32 values.
    /// @param _index The index of the uint32 value to set.
    /// @param _value The new value at the specified index.
    function set(Uint32Map storage _map, uint256 _index, uint32 _value) internal {
        unchecked {
            // Each storage slot can store 256 bits of data.
            // As uint32 is 32 bits long, 8 uint32s can be packed into one storage slot.
            // Hence, `_index / 8` is done to find the storage slot that contains the required uint32.
            uint256 mapIndex = _index / 8;
            uint256 mapValue = _map.map[mapIndex];

            // First three bits of the original `_index` denotes the position of the uint32 in that slot.
            // So, '(_index & 7) * 32' is done to find the bit position of the uint32 in that storage slot.
            uint256 bitOffset = (_index & 7) * 32;

            // XORing a value A with B, and then with A again, gives the original value B.
            // We will use this property to update the uint32 value in the slot.

            // Shift the bits to the right and retrieve the uint32 value.
            uint32 oldValue = uint32(mapValue >> bitOffset);

            // Calculate the XOR of the new value and the existing value.
            uint256 newValueXorOldValue = uint256(oldValue ^ _value);

            // Finally, we XOR the slot with the XOR of the new value and the existing value,
            // shifted to its proper position. The XOR operation will effectively replace the old value with the new value.
            _map.map[mapIndex] = (newValueXorOldValue << bitOffset) ^ mapValue;
        }
    }
}
