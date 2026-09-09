// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Fixture for the EVM emulator. Every memory access below is zero-length, which EVM
/// treats as a no-op at any offset, charging no memory expansion. The emulator therefore
/// does not validate the offset when the length is zero, so such an offset must never be
/// turned into an EraVM heap pointer: `MEM_OFFSET() + offset` comes straight from the
/// stack and wraps modulo 2**256, so it can exceed the uint32 range EraVM permits for a
/// pointer, or wrap into the emulator's own memory region.
///
/// The offset is a parameter so a single deployment can be driven with both classes of
/// dangerous value. Note `type(uint256).max` is *not* one of them: it wraps to
/// `MEM_OFFSET() - 1`, an ordinary small heap address.
contract ZeroLenMemoryOffset {
    uint256 private constant MARKER = 0xC0FFEE;

    function testCalldataCopy(uint256 offset) external pure returns (uint256) {
        assembly {
            calldatacopy(offset, 0, 0)
        }
        return MARKER;
    }

    function testCodeCopy(uint256 offset) external pure returns (uint256) {
        assembly {
            codecopy(offset, 0, 0)
        }
        return MARKER;
    }

    function testMcopy(uint256 offset) external pure returns (uint256) {
        assembly {
            mcopy(offset, offset, 0)
        }
        return MARKER;
    }

    function testReturndataCopy(uint256 offset) external pure returns (uint256) {
        assembly {
            returndatacopy(offset, 0, 0)
        }
        return MARKER;
    }

    function testExtCodeCopy(address target, uint256 offset) external view returns (uint256) {
        assembly {
            extcodecopy(target, offset, 0, 0)
        }
        return MARKER;
    }

    function testCall(address target, uint256 offset) external returns (uint256) {
        assembly {
            if iszero(call(gas(), target, 0, offset, 0, offset, 0)) {
                revert(0, 0)
            }
        }
        return MARKER;
    }

    function testStaticCall(address target, uint256 offset) external view returns (uint256) {
        assembly {
            if iszero(staticcall(gas(), target, offset, 0, offset, 0)) {
                revert(0, 0)
            }
        }
        return MARKER;
    }

    function testDelegateCall(address target, uint256 offset) external returns (uint256) {
        assembly {
            if iszero(delegatecall(gas(), target, offset, 0, offset, 0)) {
                revert(0, 0)
            }
        }
        return MARKER;
    }

    function testCreate(uint256 offset) external returns (uint256) {
        assembly {
            if iszero(create(0, offset, 0)) {
                revert(0, 0)
            }
        }
        return MARKER;
    }

    function testCreate2(uint256 offset) external returns (uint256) {
        assembly {
            if iszero(create2(0, offset, 0, 0)) {
                revert(0, 0)
            }
        }
        return MARKER;
    }
}
