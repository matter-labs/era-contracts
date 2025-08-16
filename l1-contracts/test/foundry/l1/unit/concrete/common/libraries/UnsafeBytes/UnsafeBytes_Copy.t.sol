// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UnsafeBytes} from "contracts/common/libraries/UnsafeBytes.sol";

contract UnsafeBytesHarness {
    function copyNew(bytes memory src, uint256 srcOffset, uint256 len) external pure returns (bytes memory out) {
        out = new bytes(len);
        UnsafeBytes.copy(out, 0, src, srcOffset, len);
    }

    function readRemainingBytes(bytes memory src, uint256 start) external pure returns (bytes memory) {
        return UnsafeBytes.readRemainingBytes(src, start);
    }
}

contract UnsafeBytes_CopyTest is Test {
    UnsafeBytesHarness private harness;

    function setUp() public {
        harness = new UnsafeBytesHarness();
    }

    // Reference implementation equivalent to EIP-5656 mcopy semantics (non-overlapping in our use)
    function _referenceCopy(bytes memory src, uint256 srcOffset, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        assembly {
            let dst := add(out, 0x20)
            let s := add(add(src, 0x20), srcOffset)
            let chunks := and(len, not(31))
            for {
                let i := 0
            } lt(i, chunks) {
                i := add(i, 0x20)
            } {
                mstore(add(dst, i), mload(add(s, i)))
            }
            let rem := and(len, 31)
            if rem {
                let tailDst := add(dst, chunks)
                let tailSrc := add(s, chunks)
                let remBits := shl(3, rem)
                let keepMask := shr(remBits, not(0))
                let keep := and(mload(tailDst), keepMask)
                let put := and(mload(tailSrc), not(keepMask))
                mstore(tailDst, or(put, keep))
            }
        }
    }

    function test_readRemainingBytes_edges() public {
        bytes memory data = hex"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20212223"; // 36 bytes
        // start 0
        bytes memory a = harness.readRemainingBytes(data, 0);
        bytes memory b = _referenceCopy(data, 0, data.length);
        assertEq(a, b, "start=0 full length");

        // start 1
        a = harness.readRemainingBytes(data, 1);
        b = _referenceCopy(data, 1, data.length - 1);
        assertEq(a, b, "start=1 tail 35");

        // start 31
        a = harness.readRemainingBytes(data, 31);
        b = _referenceCopy(data, 31, data.length - 31);
        assertEq(a, b, "start=31 tail 5");

        // start 32
        a = harness.readRemainingBytes(data, 32);
        b = _referenceCopy(data, 32, data.length - 32);
        assertEq(a, b, "start=32 tail 4");

        // start == len
        a = harness.readRemainingBytes(data, data.length);
        b = _referenceCopy(data, data.length, 0);
        assertEq(a, b, "start=len -> empty");
    }

    function test_fuzz_readRemainingEqualsReference(bytes memory data, uint128 start16) public {
        uint256 start = uint256(start16) % (data.length == 0 ? 1 : data.length); // allow 0..len-1
        bytes memory a = harness.readRemainingBytes(data, start);
        bytes memory b = _referenceCopy(data, start, data.length - start);
        assertEq(a, b, "readRemainingBytes != reference copy");
    }

    function test_copy_matches_reference() public {
        bytes memory data = new bytes(97);
        for (uint256 i = 0; i < 97; i++) {
            data[i] = bytes1(uint8(i));
        }
        for (uint256 start = 0; start < 97; start += 13) {
            uint256 len = 97 - start;
            bytes memory dst = harness.copyNew(data, start, len);
            bytes memory ref = _referenceCopy(data, start, len);
            assertEq(dst, ref, string(abi.encodePacked("start=", vm.toString(start))));
        }
    }

    function test_fuzz_copy_matches_reference(bytes memory data, uint64 start16, uint64 len16) public {
        uint256 start = uint256(start16) % (data.length == 0 ? 1 : data.length);
        uint256 maxLen = data.length - start;
        uint256 len = maxLen == 0 ? 0 : (uint256(len16) % (maxLen + 1));

        bytes memory dst = harness.copyNew(data, start, len);
        bytes memory ref = _referenceCopy(data, start, len);
        assertEq(dst, ref, "copy != reference");
    }
}
