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

    function test_regression_consecutiveReadsRequireOffsetUpdate() public pure {
        // Encode two different uint256 values: chainId = 7, batchNumber = 123
        uint256 chainId = 7;
        uint256 batchNumber = 123;
        bytes memory message = abi.encodePacked(
            bytes4(0x12345678), // 4 byte selector
            chainId, // 32 bytes
            batchNumber // 32 bytes
        );

        uint256 offset = 4; // Start after selector

        // CORRECT PATTERN: Capture the updated offset
        uint256 readChainId;
        (readChainId, offset) = UnsafeBytes.readUint256(message, offset);

        uint256 readBatchNumber;
        (readBatchNumber, ) = UnsafeBytes.readUint256(message, offset);

        // Both values should be read correctly
        assertEq(readChainId, chainId, "ChainId should be read correctly");
        assertEq(readBatchNumber, batchNumber, "BatchNumber should be read correctly");
        assertNotEq(readChainId, readBatchNumber, "ChainId and BatchNumber should be different");
    }

    /// @notice Demonstrates the bug pattern - what happens when offset is not captured
    /// @dev This shows that discarding the offset causes both reads to return the same value
    function test_regression_discardingOffsetCausesDuplicateReads() public pure {
        // Encode two different uint256 values
        uint256 firstValue = 42;
        uint256 secondValue = 999;
        bytes memory message = abi.encodePacked(firstValue, secondValue);

        uint256 offset = 0;

        // BUGGY PATTERN: Discard the updated offset (using _ placeholder)
        uint256 read1;
        // Note: This is the buggy pattern - we intentionally discard the offset
        (read1, ) = UnsafeBytes.readUint256(message, offset);

        uint256 read2;
        // This read uses the same offset as the first read!
        (read2, ) = UnsafeBytes.readUint256(message, offset);

        // Both reads return the SAME value because offset wasn't updated
        assertEq(read1, firstValue, "First read should return first value");
        assertEq(read2, firstValue, "Second read also returns first value (bug!)");
        assertEq(read1, read2, "Both reads return the same value when offset is discarded");
    }

    /// @notice Test the exact scenario from the bug: chainId and batchNumber decoding
    /// @dev Simulates the L1MessageRoot.saveV30UpgradeChainBatchNumberOnL1 message format
    function test_regression_v30UpgradeMessageDecodingPattern() public pure {
        // Simulate the message format that was being decoded
        // Format: selector (4 bytes) + chainId (32 bytes) + v30UpgradeChainBatchNumber (32 bytes)
        bytes4 functionSelector = bytes4(keccak256("saveV30UpgradeChainBatchNumberOnL1()"));
        uint256 expectedChainId = 270; // ZKSync Era chain ID
        uint256 expectedBatchNumber = 50000; // Some batch number

        bytes memory message = abi.encodePacked(functionSelector, expectedChainId, expectedBatchNumber);

        // Read selector and update offset
        uint256 offset = 0;
        (uint32 selector, ) = UnsafeBytes.readUint32(message, offset);
        offset = 4; // After selector

        // CORRECT: Read chainId and capture the new offset
        uint256 decodedChainId;
        (decodedChainId, offset) = UnsafeBytes.readUint256(message, offset);

        // CORRECT: Read batchNumber using the updated offset
        uint256 decodedBatchNumber;
        (decodedBatchNumber, ) = UnsafeBytes.readUint256(message, offset);

        // Verify correct decoding
        assertEq(bytes4(bytes32(uint256(selector) << 224)), functionSelector, "Selector mismatch");
        assertEq(decodedChainId, expectedChainId, "ChainId should match");
        assertEq(decodedBatchNumber, expectedBatchNumber, "BatchNumber should match");

        // Key assertion: The values should be different!
        // Before the fix, decodedBatchNumber would equal decodedChainId (270)
        assertNotEq(decodedChainId, decodedBatchNumber, "ChainId and BatchNumber should be different values");
    }

    /// @notice Fuzz test for consecutive uint256 reads with proper offset handling
    function testFuzz_regression_consecutiveUint256Reads(uint256 value1, uint256 value2) public pure {
        bytes memory data = abi.encodePacked(value1, value2);

        uint256 offset = 0;
        uint256 read1;
        uint256 read2;

        // Correctly capture offset
        (read1, offset) = UnsafeBytes.readUint256(data, offset);
        (read2, offset) = UnsafeBytes.readUint256(data, offset);

        assertEq(read1, value1, "First value should be read correctly");
        assertEq(read2, value2, "Second value should be read correctly");
        assertEq(offset, 64, "Final offset should be 64 (2 * 32 bytes)");
    }
}
