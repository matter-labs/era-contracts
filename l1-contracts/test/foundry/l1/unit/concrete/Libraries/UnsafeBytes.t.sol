// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UnsafeBytes} from "contracts/common/libraries/UnsafeBytes.sol";

/// @notice Unit tests for UnsafeBytes library
contract UnsafeBytesTest is Test {
    // ============ readUint32 Tests ============

    function test_readUint32_atStart() public pure {
        uint32 expected = 0x12345678;
        bytes memory data = abi.encodePacked(expected);

        (uint32 result, uint256 offset) = UnsafeBytes.readUint32(data, 0);

        assertEq(result, expected);
        assertEq(offset, 4);
    }

    function test_readUint32_atOffset() public pure {
        bytes memory data = abi.encodePacked(
            uint32(0xAAAAAAAA), // offset 0-3
            uint32(0x12345678) // offset 4-7
        );

        (uint32 result, uint256 offset) = UnsafeBytes.readUint32(data, 4);

        assertEq(result, 0x12345678);
        assertEq(offset, 8);
    }

    function test_readUint32_multipleReads() public pure {
        bytes memory data = abi.encodePacked(uint32(100), uint32(200), uint32(300));

        (uint32 result1, uint256 offset1) = UnsafeBytes.readUint32(data, 0);
        (uint32 result2, uint256 offset2) = UnsafeBytes.readUint32(data, offset1);
        (uint32 result3, uint256 offset3) = UnsafeBytes.readUint32(data, offset2);

        assertEq(result1, 100);
        assertEq(result2, 200);
        assertEq(result3, 300);
        assertEq(offset3, 12);
    }

    function testFuzz_readUint32(uint32 value) public pure {
        bytes memory data = abi.encodePacked(value);

        (uint32 result, uint256 offset) = UnsafeBytes.readUint32(data, 0);

        assertEq(result, value);
        assertEq(offset, 4);
    }

    // ============ readAddress Tests ============

    function test_readAddress_atStart() public pure {
        address expected = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        bytes memory data = abi.encodePacked(expected);

        (address result, uint256 offset) = UnsafeBytes.readAddress(data, 0);

        assertEq(result, expected);
        assertEq(offset, 20);
    }

    function test_readAddress_atOffset() public pure {
        bytes memory data = abi.encodePacked(
            uint32(0xAAAAAAAA), // 4 bytes
            address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF)
        );

        (address result, uint256 offset) = UnsafeBytes.readAddress(data, 4);

        assertEq(result, address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF));
        assertEq(offset, 24);
    }

    function testFuzz_readAddress(address value) public pure {
        bytes memory data = abi.encodePacked(value);

        (address result, uint256 offset) = UnsafeBytes.readAddress(data, 0);

        assertEq(result, value);
        assertEq(offset, 20);
    }

    // ============ readUint256 Tests ============

    function test_readUint256_atStart() public pure {
        uint256 expected = 12345678901234567890;
        bytes memory data = abi.encodePacked(expected);

        (uint256 result, uint256 offset) = UnsafeBytes.readUint256(data, 0);

        assertEq(result, expected);
        assertEq(offset, 32);
    }

    function test_readUint256_maxValue() public pure {
        uint256 expected = type(uint256).max;
        bytes memory data = abi.encodePacked(expected);

        (uint256 result, uint256 offset) = UnsafeBytes.readUint256(data, 0);

        assertEq(result, expected);
        assertEq(offset, 32);
    }

    function test_readUint256_atOffset() public pure {
        bytes memory data = abi.encodePacked(
            uint64(0xAAAAAAAAAAAAAAAA), // 8 bytes
            uint256(0x123456789)
        );

        (uint256 result, uint256 offset) = UnsafeBytes.readUint256(data, 8);

        assertEq(result, 0x123456789);
        assertEq(offset, 40);
    }

    function testFuzz_readUint256(uint256 value) public pure {
        bytes memory data = abi.encodePacked(value);

        (uint256 result, uint256 offset) = UnsafeBytes.readUint256(data, 0);

        assertEq(result, value);
        assertEq(offset, 32);
    }

    // ============ readBytes32 Tests ============

    function test_readBytes32_atStart() public pure {
        bytes32 expected = keccak256("test");
        bytes memory data = abi.encodePacked(expected);

        (bytes32 result, uint256 offset) = UnsafeBytes.readBytes32(data, 0);

        assertEq(result, expected);
        assertEq(offset, 32);
    }

    function test_readBytes32_atOffset() public pure {
        bytes memory data = abi.encodePacked(
            uint64(0xBBBBBBBBBBBBBBBB), // 8 bytes
            bytes32(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef)
        );

        (bytes32 result, uint256 offset) = UnsafeBytes.readBytes32(data, 8);

        assertEq(result, bytes32(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef));
        assertEq(offset, 40);
    }

    function testFuzz_readBytes32(bytes32 value) public pure {
        bytes memory data = abi.encodePacked(value);

        (bytes32 result, uint256 offset) = UnsafeBytes.readBytes32(data, 0);

        assertEq(result, value);
        assertEq(offset, 32);
    }

    // ============ readRemainingBytes Tests ============

    function test_readRemainingBytes_fromStart() public pure {
        bytes memory data = hex"0102030405";

        bytes memory result = UnsafeBytes.readRemainingBytes(data, 0);

        assertEq(result.length, 5);
        assertEq(result, data);
    }

    function test_readRemainingBytes_fromOffset() public pure {
        bytes memory data = hex"0102030405060708";

        bytes memory result = UnsafeBytes.readRemainingBytes(data, 3);

        assertEq(result.length, 5);
        assertEq(result, hex"0405060708");
    }

    function test_readRemainingBytes_emptyResult() public pure {
        bytes memory data = hex"0102030405";

        bytes memory result = UnsafeBytes.readRemainingBytes(data, 5);

        assertEq(result.length, 0);
    }

    function test_readRemainingBytes_singleByte() public pure {
        bytes memory data = hex"0102030405";

        bytes memory result = UnsafeBytes.readRemainingBytes(data, 4);

        assertEq(result.length, 1);
        assertEq(result, hex"05");
    }

    // ============ Integration Tests ============

    function test_readMixedData() public pure {
        // Build a complex data structure
        bytes memory data = abi.encodePacked(
            uint32(0x11223344),
            address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF),
            uint256(9999),
            bytes32(keccak256("hello"))
        );

        uint256 offset = 0;
        uint32 val32;
        address addr;
        uint256 val256;
        bytes32 hash;

        (val32, offset) = UnsafeBytes.readUint32(data, offset);
        assertEq(val32, 0x11223344);

        (addr, offset) = UnsafeBytes.readAddress(data, offset);
        assertEq(addr, address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF));

        (val256, offset) = UnsafeBytes.readUint256(data, offset);
        assertEq(val256, 9999);

        (hash, offset) = UnsafeBytes.readBytes32(data, offset);
        assertEq(hash, keccak256("hello"));

        assertEq(offset, 4 + 20 + 32 + 32); // Total bytes read
    }

    function test_readWithRemainingBytes() public pure {
        bytes memory trailer = hex"DEADBEEF";
        bytes memory data = abi.encodePacked(uint32(123), uint256(456), trailer);

        uint256 offset = 0;
        uint32 val32;
        uint256 val256;

        (val32, offset) = UnsafeBytes.readUint32(data, offset);
        (val256, offset) = UnsafeBytes.readUint256(data, offset);

        bytes memory remaining = UnsafeBytes.readRemainingBytes(data, offset);

        assertEq(val32, 123);
        assertEq(val256, 456);
        assertEq(remaining, trailer);
    }
}
