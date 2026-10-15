// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UnsafeBytes} from "contracts/common/libraries/UnsafeBytes.sol";
import {RAND_ADDRESS} from "test/foundry/TestConstants.sol";

/// @notice Unit tests for UnsafeBytes library
contract UnsafeBytesLibraryTest is Test {
    // ============ readUint32 Tests ============

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

    function testFuzz_readUint32(uint32 _value) public pure {
        bytes memory data = abi.encodePacked(_value);

        (uint32 result, uint256 offset) = UnsafeBytes.readUint32(data, 0);

        assertEq(result, _value);
        assertEq(offset, 4);
    }

    // ============ readAddress Tests ============

    function testFuzz_readAddress(address _value) public pure {
        bytes memory data = abi.encodePacked(_value);

        (address result, uint256 offset) = UnsafeBytes.readAddress(data, 0);

        assertEq(result, _value);
        assertEq(offset, 20);
    }

    // ============ readUint256 Tests ============

    function testFuzz_readUint256(uint256 _value) public pure {
        bytes memory data = abi.encodePacked(_value);

        (uint256 result, uint256 offset) = UnsafeBytes.readUint256(data, 0);

        assertEq(result, _value);
        assertEq(offset, 32);
    }

    // ============ readBytes32 Tests ============

    function testFuzz_readBytes32(bytes32 _value) public pure {
        bytes memory data = abi.encodePacked(_value);

        (bytes32 result, uint256 offset) = UnsafeBytes.readBytes32(data, 0);

        assertEq(result, _value);
        assertEq(offset, 32);
    }

    // ============ readRemainingBytes Tests ============

    function test_readRemainingBytes_emptyResult() public pure {
        bytes memory data = hex"0102030405";

        bytes memory result = UnsafeBytes.readRemainingBytes(data, 5);

        assertEq(result.length, 0);
    }

    // ============ Integration Tests ============

    function test_readMixedData() public pure {
        bytes memory data = abi.encodePacked(
            uint32(0x11223344),
            RAND_ADDRESS,
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
        assertEq(addr, RAND_ADDRESS);

        (val256, offset) = UnsafeBytes.readUint256(data, offset);
        assertEq(val256, 9999);

        (hash, offset) = UnsafeBytes.readBytes32(data, offset);
        assertEq(hash, keccak256("hello"));

        assertEq(offset, 4 + 20 + 32 + 32);
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

    /// @notice Regression for the L1MessageRoot.saveV30UpgradeChainBatchNumberOnL1 decoding bug: the second read has
    /// to start at the offset returned by the first one.
    function testFuzz_regression_consecutiveUint256Reads(uint256 _value1, uint256 _value2) public pure {
        bytes memory data = abi.encodePacked(_value1, _value2);

        uint256 offset = 0;
        uint256 read1;
        uint256 read2;

        (read1, offset) = UnsafeBytes.readUint256(data, offset);
        (read2, offset) = UnsafeBytes.readUint256(data, offset);

        assertEq(read1, _value1, "First value should be read correctly");
        assertEq(read2, _value2, "Second value should be read correctly");
        assertEq(offset, 64, "Final offset should be 64 (2 * 32 bytes)");
    }
}
