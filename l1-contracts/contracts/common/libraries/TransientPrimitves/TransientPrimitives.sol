// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @author philogy <https://github.com/philogy>

struct tuint256 {
    uint256 __placeholder;
}

struct tint256 {
    uint256 __placeholder;
}

struct tbytes32 {
    uint256 __placeholder;
}

struct taddress {
    uint256 __placeholder;
}

using TransientPrimitivesLib for tuint256 global;
using TransientPrimitivesLib for tint256 global;
using TransientPrimitivesLib for tbytes32 global;
using TransientPrimitivesLib for taddress global;

library TransientPrimitivesLib {
    error ArithmeticOverflowUnderflow();

    function getUint256(uint256 slot) internal view returns (uint256 value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := tload(slot)
        }
    }

    // function get(uint256 slot) internal view returns (int256 value) {
    //     /// @solidity memory-safe-assembly
    //     assembly {
    //         value := tload(ptr.slot)
    //     }
    // }

    // function getBytes(tbytes32 memory ptr) internal view returns (bytes32 value) {
    //     /// @solidity memory-safe-assembly
    //     assembly {
    //         value := tload(ptr.slot)
    //     }
    // }

    // function getAddress(taddress memory ptr) internal view returns (address value) {
    //     /// @solidity memory-safe-assembly
    //     assembly {
    //         value := tload(ptr.slot)
    //     }
    // }

    function set(uint256 slot, uint256 value) internal {
        /// @solidity memory-safe-assembly
        assembly {
            tstore(slot, value)
        }
    }

    // function inc(tuint256 memory ptr, uint256 change) internal returns (uint256 newValue) {
    //     ptr.set(newValue = ptr.get() + change);
    // }

    // function dec(tuint256 memory ptr, uint256 change) internal returns (uint256 newValue) {
    //     ptr.set(newValue = ptr.get() - change);
    // }

    // function inc(tuint256 memory ptr, int256 change) internal returns (uint256 newValue) {
    //     uint256 currentValue = ptr.get();
    //     assembly ("memory-safe") {
    //         newValue := add(currentValue, change)
    //         if iszero(eq(lt(newValue, currentValue), slt(change, 0))) {
    //             mstore(0x00, 0xc9654ed4 /* ArithmeticOverflowUnderflow() */ )
    //             revert(0x1c, 0x04)
    //         }
    //     }
    //     ptr.set(newValue);
    // }

    // function dec(tuint256 memory ptr, int256 change) internal returns (uint256 newValue) {
    //     uint256 currentValue = ptr.get();
    //     assembly ("memory-safe") {
    //         newValue := sub(currentValue, change)
    //         if iszero(eq(lt(newValue, currentValue), sgt(change, 0))) {
    //             mstore(0x00, 0xc9654ed4 /* ArithmeticOverflowUnderflow() */ )
    //             revert(0x1c, 0x04)
    //         }
    //     }
    //     ptr.set(newValue);
    // }

    // function set(tint256 memory ptr, int256 value) internal {
    //     /// @solidity memory-safe-assembly
    //     assembly {
    //         tstore(ptr.slot, value)
    //     }
    // }

    // function inc(tint256 memory ptr, int256 change) internal returns (int256 newValue) {
    //     ptr.set(newValue = ptr.get() + change);
    // }

    // function dec(tint256 memory ptr, int256 change) internal returns (int256 newValue) {
    //     ptr.set(newValue = ptr.get() - change);
    // }

    // function set(tbytes32 memory ptr, bytes32 value) internal {
    //     /// @solidity memory-safe-assembly
    //     assembly {
    //         tstore(ptr.slot, value)
    //     }
    // }

    // function set(taddress memory ptr, address value) internal {
    //     /// @solidity memory-safe-assembly
    //     assembly {
    //         tstore(ptr.slot, value)
    //     }
    // }
}
