// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Bytes} from "contracts/vendor/Bytes.sol";

/// @notice Unit tests for Bytes library
contract BytesTest is Test {
    using Bytes for bytes;

    // ============ indexOf Tests ============

    function test_indexOf_findsFirstOccurrence() public pure {
        bytes memory buffer = hex"0102030405";
        uint256 index = buffer.indexOf(bytes1(0x03));
        assertEq(index, 2);
    }

    function test_indexOf_returnsMaxWhenNotFound() public pure {
        bytes memory buffer = hex"0102030405";
        uint256 index = buffer.indexOf(bytes1(0xFF));
        assertEq(index, type(uint256).max);
    }

    function test_indexOf_emptyBuffer() public pure {
        bytes memory buffer = "";
        uint256 index = buffer.indexOf(bytes1(0x01));
        assertEq(index, type(uint256).max);
    }

    function test_indexOf_findsAtStart() public pure {
        bytes memory buffer = hex"0102030405";
        uint256 index = buffer.indexOf(bytes1(0x01));
        assertEq(index, 0);
    }

    function test_indexOf_findsAtEnd() public pure {
        bytes memory buffer = hex"0102030405";
        uint256 index = buffer.indexOf(bytes1(0x05));
        assertEq(index, 4);
    }

    // ============ indexOf with position Tests ============

    function test_indexOf_withPosition_findsAfterPos() public pure {
        bytes memory buffer = hex"01020301020304";
        // Find 0x03 starting from position 3
        // buffer[0]=0x01, buffer[1]=0x02, buffer[2]=0x03, buffer[3]=0x01, buffer[4]=0x02, buffer[5]=0x03, buffer[6]=0x04
        uint256 index = buffer.indexOf(bytes1(0x03), 3);
        assertEq(index, 5);
    }

    function test_indexOf_withPosition_returnsMaxIfNotFoundAfterPos() public pure {
        bytes memory buffer = hex"0102030405";
        // 0x01 is at position 0, but we start from position 1
        uint256 index = buffer.indexOf(bytes1(0x01), 1);
        assertEq(index, type(uint256).max);
    }

    function test_indexOf_withPosition_findsAtPos() public pure {
        bytes memory buffer = hex"0102030405";
        uint256 index = buffer.indexOf(bytes1(0x03), 2);
        assertEq(index, 2);
    }

    function test_indexOf_withPosition_posBeyondLength() public pure {
        bytes memory buffer = hex"0102030405";
        uint256 index = buffer.indexOf(bytes1(0x01), 100);
        assertEq(index, type(uint256).max);
    }

    // ============ slice Tests ============

    function test_slice_fromStart() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.slice(0);
        assertEq(result, hex"0102030405");
    }

    function test_slice_fromMiddle() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.slice(2);
        assertEq(result, hex"030405");
    }

    function test_slice_fromEnd() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.slice(5);
        assertEq(result, hex"");
    }

    function test_slice_beyondLength() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.slice(100);
        assertEq(result, hex"");
    }

    // ============ slice with end Tests ============

    function test_slice_withEnd_middle() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.slice(1, 4);
        assertEq(result, hex"020304");
    }

    function test_slice_withEnd_fullBuffer() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.slice(0, 5);
        assertEq(result, hex"0102030405");
    }

    function test_slice_withEnd_endBeyondLength() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.slice(2, 100);
        assertEq(result, hex"030405");
    }

    function test_slice_withEnd_startEqualsEnd() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.slice(2, 2);
        assertEq(result, hex"");
    }

    function test_slice_withEnd_startGreaterThanEnd() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.slice(4, 2);
        assertEq(result, hex"");
    }

    // ============ splice Tests ============

    function test_splice_fromStart() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.splice(0);
        assertEq(result, hex"0102030405");
        assertEq(buffer, result); // splice modifies in place
    }

    function test_splice_fromMiddle() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.splice(2);
        assertEq(result, hex"030405");
    }

    function test_splice_fromEnd() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.splice(5);
        assertEq(result, hex"");
    }

    // ============ splice with end Tests ============

    function test_splice_withEnd_middle() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.splice(1, 4);
        assertEq(result, hex"020304");
    }

    function test_splice_withEnd_endBeyondLength() public pure {
        bytes memory buffer = hex"0102030405";
        bytes memory result = buffer.splice(2, 100);
        assertEq(result, hex"030405");
    }

    // ============ equal Tests ============

    function test_equal_sameContent() public pure {
        bytes memory a = hex"0102030405";
        bytes memory b = hex"0102030405";
        assertTrue(a.equal(b));
    }

    function test_equal_differentContent() public pure {
        bytes memory a = hex"0102030405";
        bytes memory b = hex"0102030406";
        assertFalse(a.equal(b));
    }

    function test_equal_differentLength() public pure {
        bytes memory a = hex"0102030405";
        bytes memory b = hex"010203";
        assertFalse(a.equal(b));
    }

    function test_equal_emptyBuffers() public pure {
        bytes memory a = "";
        bytes memory b = "";
        assertTrue(a.equal(b));
    }

    function test_equal_oneEmpty() public pure {
        bytes memory a = hex"01";
        bytes memory b = "";
        assertFalse(a.equal(b));
    }

    // ============ reverseBytes32 Tests ============

    function test_reverseBytes32() public pure {
        bytes32 input = 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20;
        bytes32 expected = 0x201f1e1d1c1b1a191817161514131211100f0e0d0c0b0a090807060504030201;
        assertEq(Bytes.reverseBytes32(input), expected);
    }

    function test_reverseBytes32_zeros() public pure {
        bytes32 input = bytes32(0);
        assertEq(Bytes.reverseBytes32(input), bytes32(0));
    }

    function test_reverseBytes32_allOnes() public pure {
        bytes32 input = bytes32(type(uint256).max);
        assertEq(Bytes.reverseBytes32(input), bytes32(type(uint256).max));
    }

    function test_reverseBytes32_doubleReverse() public pure {
        bytes32 input = 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20;
        assertEq(Bytes.reverseBytes32(Bytes.reverseBytes32(input)), input);
    }

    // ============ reverseBytes16 Tests ============

    function test_reverseBytes16() public pure {
        bytes16 input = 0x0102030405060708090a0b0c0d0e0f10;
        bytes16 expected = 0x100f0e0d0c0b0a090807060504030201;
        bytes16 result = Bytes.reverseBytes16(input);
        assertEq(bytes32(result), bytes32(expected));
    }

    function test_reverseBytes16_zeros() public pure {
        bytes16 input = bytes16(0);
        assertEq(bytes32(Bytes.reverseBytes16(input)), bytes32(bytes16(0)));
    }

    function test_reverseBytes16_doubleReverse() public pure {
        bytes16 input = 0x0102030405060708090a0b0c0d0e0f10;
        assertEq(bytes32(Bytes.reverseBytes16(Bytes.reverseBytes16(input))), bytes32(input));
    }

    // ============ reverseBytes8 Tests ============

    function test_reverseBytes8() public pure {
        bytes8 input = 0x0102030405060708;
        bytes8 expected = 0x0807060504030201;
        assertEq(bytes32(Bytes.reverseBytes8(input)), bytes32(expected));
    }

    function test_reverseBytes8_zeros() public pure {
        bytes8 input = bytes8(0);
        assertEq(bytes32(Bytes.reverseBytes8(input)), bytes32(bytes8(0)));
    }

    function test_reverseBytes8_doubleReverse() public pure {
        bytes8 input = 0x0102030405060708;
        assertEq(bytes32(Bytes.reverseBytes8(Bytes.reverseBytes8(input))), bytes32(input));
    }

    // ============ reverseBytes4 Tests ============

    function test_reverseBytes4() public pure {
        bytes4 input = 0x01020304;
        bytes4 expected = 0x04030201;
        assertEq(bytes32(Bytes.reverseBytes4(input)), bytes32(expected));
    }

    function test_reverseBytes4_zeros() public pure {
        bytes4 input = bytes4(0);
        assertEq(bytes32(Bytes.reverseBytes4(input)), bytes32(bytes4(0)));
    }

    function test_reverseBytes4_doubleReverse() public pure {
        bytes4 input = 0x01020304;
        assertEq(bytes32(Bytes.reverseBytes4(Bytes.reverseBytes4(input))), bytes32(input));
    }

    // ============ reverseBytes2 Tests ============

    function test_reverseBytes2() public pure {
        bytes2 input = 0x0102;
        bytes2 expected = 0x0201;
        assertEq(bytes32(Bytes.reverseBytes2(input)), bytes32(expected));
    }

    function test_reverseBytes2_zeros() public pure {
        bytes2 input = bytes2(0);
        assertEq(bytes32(Bytes.reverseBytes2(input)), bytes32(bytes2(0)));
    }

    function test_reverseBytes2_doubleReverse() public pure {
        bytes2 input = 0x0102;
        assertEq(bytes32(Bytes.reverseBytes2(Bytes.reverseBytes2(input))), bytes32(input));
    }

    // ============ Fuzz Tests ============

    function testFuzz_reverseBytes32_doubleReverse(bytes32 input) public pure {
        assertEq(Bytes.reverseBytes32(Bytes.reverseBytes32(input)), input);
    }

    function testFuzz_reverseBytes16_doubleReverse(bytes16 input) public pure {
        assertEq(bytes32(Bytes.reverseBytes16(Bytes.reverseBytes16(input))), bytes32(input));
    }

    function testFuzz_reverseBytes8_doubleReverse(bytes8 input) public pure {
        assertEq(bytes32(Bytes.reverseBytes8(Bytes.reverseBytes8(input))), bytes32(input));
    }

    function testFuzz_reverseBytes4_doubleReverse(bytes4 input) public pure {
        assertEq(bytes32(Bytes.reverseBytes4(Bytes.reverseBytes4(input))), bytes32(input));
    }

    function testFuzz_reverseBytes2_doubleReverse(bytes2 input) public pure {
        assertEq(bytes32(Bytes.reverseBytes2(Bytes.reverseBytes2(input))), bytes32(input));
    }

    function testFuzz_equal_reflexive(bytes memory a) public pure {
        assertTrue(a.equal(a));
    }

    function testFuzz_slice_preservesLength(bytes memory buffer, uint256 start, uint256 end) public pure {
        vm.assume(buffer.length < 1000); // Limit for gas
        bytes memory result = buffer.slice(start, end);
        // Result length should be min(end, len) - min(start, min(end, len))
        uint256 len = buffer.length;
        uint256 sanitizedEnd = end < len ? end : len;
        uint256 sanitizedStart = start < sanitizedEnd ? start : sanitizedEnd;
        assertEq(result.length, sanitizedEnd - sanitizedStart);
    }
}
