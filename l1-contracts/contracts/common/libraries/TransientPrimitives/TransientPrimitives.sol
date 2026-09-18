// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @author philogy <https://github.com/philogy>
/// @notice TransientPrimitivesLib is a library for storing and retrieving transient values in the EVM.
library TransientPrimitivesLib {
    function getUint256(uint256 slot) internal view returns (uint256 value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := tload(slot)
        }
    }

    function set(uint256 slot, uint256 value) internal {
        /// @solidity memory-safe-assembly
        assembly {
            tstore(slot, value)
        }
    }
}
