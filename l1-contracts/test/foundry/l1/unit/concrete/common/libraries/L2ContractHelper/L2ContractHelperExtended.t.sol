// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {BytecodeError, LengthIsNotDivisibleBy32, MalformedBytecode} from "contracts/common/L1ContractErrors.sol";

/// @notice Extended unit tests for L2ContractHelper library
contract L2ContractHelperExtendedTest is Test {
    // ============ bytecodeLen Tests ============

    function test_bytecodeLen_returnsCorrectLength() public pure {
        // Bytecode hash with length 1 word
        bytes32 bytecodeHash = bytes32(0x01000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);
        uint256 len = L2ContractHelper.bytecodeLen(bytecodeHash);
        assertEq(len, 1);
    }

    function test_bytecodeLen_returnsCorrectLengthForMultipleWords() public pure {
        // Bytecode hash with length 255 words (0x00FF)
        bytes32 bytecodeHash = bytes32(0x0100FFFFf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);
        uint256 len = L2ContractHelper.bytecodeLen(bytecodeHash);
        assertEq(len, 0xFFFF);
    }

    function test_bytecodeLen_returnsZeroForZeroHash() public pure {
        bytes32 bytecodeHash = bytes32(0);
        uint256 len = L2ContractHelper.bytecodeLen(bytecodeHash);
        assertEq(len, 0);
    }

    function test_bytecodeLen_extractsFromCorrectBytes() public pure {
        // Length is stored in bytes 2 and 3 (0-indexed)
        // 0x01 00 12 34 ... means length = 0x1234 = 4660
        bytes32 bytecodeHash = bytes32(0x01001234f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);
        uint256 len = L2ContractHelper.bytecodeLen(bytecodeHash);
        assertEq(len, 0x1234);
    }

    // ============ computeCreateAddress Tests ============

    function test_computeCreateAddress_deterministicForSameInputs() public pure {
        address sender = address(0x1234);
        uint256 nonce = 5;

        address addr1 = L2ContractHelper.computeCreateAddress(sender, nonce);
        address addr2 = L2ContractHelper.computeCreateAddress(sender, nonce);

        assertEq(addr1, addr2);
    }

    function test_computeCreateAddress_differentForDifferentNonces() public pure {
        address sender = address(0x1234);

        address addr1 = L2ContractHelper.computeCreateAddress(sender, 0);
        address addr2 = L2ContractHelper.computeCreateAddress(sender, 1);
        address addr3 = L2ContractHelper.computeCreateAddress(sender, 2);

        assertTrue(addr1 != addr2);
        assertTrue(addr2 != addr3);
        assertTrue(addr1 != addr3);
    }

    function test_computeCreateAddress_differentForDifferentSenders() public pure {
        uint256 nonce = 0;

        address addr1 = L2ContractHelper.computeCreateAddress(address(0x1), nonce);
        address addr2 = L2ContractHelper.computeCreateAddress(address(0x2), nonce);

        assertTrue(addr1 != addr2);
    }

    function test_computeCreateAddress_zeroSenderAndNonce() public pure {
        address addr = L2ContractHelper.computeCreateAddress(address(0), 0);
        // Should produce a valid non-zero address
        assertTrue(addr != address(0));
    }

    function test_computeCreateAddress_largeNonce() public pure {
        address sender = address(0x1234);
        uint256 largeNonce = type(uint256).max;

        address addr = L2ContractHelper.computeCreateAddress(sender, largeNonce);
        assertTrue(addr != address(0));
    }

    // ============ hashL2BytecodeCalldata Tests ============
    // Note: hashL2BytecodeCalldata requires calldata input, so we test via external calls

    function test_hashL2BytecodeCalldata_sameAsMemoryVersion() public {
        bytes memory bytecode = new bytes(32);
        // Fill with some data
        for (uint256 i = 0; i < 32; i++) {
            bytecode[i] = bytes1(uint8(i));
        }

        bytes32 memoryHash = L2ContractHelper.hashL2Bytecode(bytecode);
        bytes32 calldataHash = this.hashCalldataExternal(bytecode);

        assertEq(memoryHash, calldataHash);
    }

    function test_hashL2BytecodeCalldata_revertsOnNonDivisibleBy32() public {
        bytes memory bytecode = new bytes(63);

        vm.expectRevert(abi.encodeWithSelector(LengthIsNotDivisibleBy32.selector, 63));
        this.hashCalldataExternal(bytecode);
    }

    function test_hashL2BytecodeCalldata_revertsOnEvenWordCount() public {
        bytes memory bytecode = new bytes(64);

        vm.expectRevert(abi.encodeWithSelector(MalformedBytecode.selector, BytecodeError.WordsMustBeOdd));
        this.hashCalldataExternal(bytecode);
    }

    // External function to get calldata parameter
    function hashCalldataExternal(bytes calldata _bytecode) external pure returns (bytes32) {
        return L2ContractHelper.hashL2BytecodeCalldata(_bytecode);
    }

    // ============ hashFactoryDeps Tests ============

    function test_hashFactoryDeps_emptyArray() public pure {
        bytes[] memory factoryDeps = new bytes[](0);

        uint256[] memory hashed = L2ContractHelper.hashFactoryDeps(factoryDeps);

        assertEq(hashed.length, 0);
    }

    function test_hashFactoryDeps_singleDep() public pure {
        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = new bytes(32); // 1 word (odd)

        uint256[] memory hashed = L2ContractHelper.hashFactoryDeps(factoryDeps);

        assertEq(hashed.length, 1);
        // Verify it matches the individual hash
        bytes32 expectedHash = L2ContractHelper.hashL2Bytecode(factoryDeps[0]);
        assertEq(bytes32(hashed[0]), expectedHash);
    }

    function test_hashFactoryDeps_multipleDeps() public pure {
        bytes[] memory factoryDeps = new bytes[](3);
        factoryDeps[0] = new bytes(32); // 1 word (odd)
        factoryDeps[1] = new bytes(96); // 3 words (odd)
        factoryDeps[2] = new bytes(160); // 5 words (odd)

        uint256[] memory hashed = L2ContractHelper.hashFactoryDeps(factoryDeps);

        assertEq(hashed.length, 3);

        // Verify each hash matches
        for (uint256 i = 0; i < 3; i++) {
            bytes32 expectedHash = L2ContractHelper.hashL2Bytecode(factoryDeps[i]);
            assertEq(bytes32(hashed[i]), expectedHash);
        }
    }

    function test_hashFactoryDeps_preservesOrder() public pure {
        bytes[] memory factoryDeps = new bytes[](2);

        // Create distinguishable bytecodes
        factoryDeps[0] = new bytes(32);
        factoryDeps[0][0] = 0x11;

        factoryDeps[1] = new bytes(32);
        factoryDeps[1][0] = 0x22;

        uint256[] memory hashed = L2ContractHelper.hashFactoryDeps(factoryDeps);

        bytes32 hash0 = L2ContractHelper.hashL2Bytecode(factoryDeps[0]);
        bytes32 hash1 = L2ContractHelper.hashL2Bytecode(factoryDeps[1]);

        assertEq(bytes32(hashed[0]), hash0);
        assertEq(bytes32(hashed[1]), hash1);
        assertTrue(hashed[0] != hashed[1]);
    }

    // ============ computeCreate2Address Additional Tests ============

    function test_computeCreate2Address_differentSaltsProduceDifferentAddresses() public pure {
        address sender = address(0x1234);
        bytes32 bytecodeHash = bytes32(0x01000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);
        bytes32 constructorInputHash = keccak256(abi.encode("test"));

        address addr1 = L2ContractHelper.computeCreate2Address(
            sender,
            bytes32(uint256(1)),
            bytecodeHash,
            constructorInputHash
        );
        address addr2 = L2ContractHelper.computeCreate2Address(
            sender,
            bytes32(uint256(2)),
            bytecodeHash,
            constructorInputHash
        );

        assertTrue(addr1 != addr2);
    }

    function test_computeCreate2Address_zeroInputs() public pure {
        address addr = L2ContractHelper.computeCreate2Address(address(0), bytes32(0), bytes32(0), bytes32(0));
        // Should still produce a deterministic address
        assertTrue(addr != address(0));
    }

    // ============ validateBytecodeHash Additional Tests ============

    function test_validateBytecodeHash_revertsOnSecondByteNotZero() public {
        // Second byte is 0x01 instead of 0x00
        bytes32 bytecodeHash = bytes32(0x01010001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        vm.expectRevert(abi.encodeWithSelector(MalformedBytecode.selector, BytecodeError.Version));
        L2ContractHelper.validateBytecodeHash(bytecodeHash);
    }

    function test_validateBytecodeHash_acceptsOddWordCounts() public pure {
        // Test various odd word counts: 1, 3, 5, 7, etc.
        bytes32 hash1 = bytes32(0x01000001f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);
        bytes32 hash3 = bytes32(0x01000003f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);
        bytes32 hash5 = bytes32(0x01000005f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);
        bytes32 hash7 = bytes32(0x01000007f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        // These should all pass validation
        L2ContractHelper.validateBytecodeHash(hash1);
        L2ContractHelper.validateBytecodeHash(hash3);
        L2ContractHelper.validateBytecodeHash(hash5);
        L2ContractHelper.validateBytecodeHash(hash7);
    }

    function test_validateBytecodeHash_revertsOnEvenWordCounts() public {
        bytes32 hash2 = bytes32(0x01000002f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);
        bytes32 hash4 = bytes32(0x01000004f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);
        bytes32 hash6 = bytes32(0x01000006f862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925);

        vm.expectRevert(abi.encodeWithSelector(MalformedBytecode.selector, BytecodeError.WordsMustBeOdd));
        L2ContractHelper.validateBytecodeHash(hash2);

        vm.expectRevert(abi.encodeWithSelector(MalformedBytecode.selector, BytecodeError.WordsMustBeOdd));
        L2ContractHelper.validateBytecodeHash(hash4);

        vm.expectRevert(abi.encodeWithSelector(MalformedBytecode.selector, BytecodeError.WordsMustBeOdd));
        L2ContractHelper.validateBytecodeHash(hash6);
    }

    // ============ hashL2Bytecode Additional Tests ============

    function test_hashL2Bytecode_differentBytecodesDifferentHashes() public pure {
        bytes memory bytecode1 = new bytes(32);
        bytecode1[0] = 0x11;

        bytes memory bytecode2 = new bytes(32);
        bytecode2[0] = 0x22;

        bytes32 hash1 = L2ContractHelper.hashL2Bytecode(bytecode1);
        bytes32 hash2 = L2ContractHelper.hashL2Bytecode(bytecode2);

        assertTrue(hash1 != hash2);
    }

    function test_hashL2Bytecode_hashHasCorrectVersionAndLength() public pure {
        bytes memory bytecode = new bytes(96); // 3 words

        bytes32 hash = L2ContractHelper.hashL2Bytecode(bytecode);

        // Check version byte (should be 1)
        assertEq(uint8(hash[0]), 1);
        // Check second byte (should be 0)
        assertEq(uint8(hash[1]), 0);
        // Check length (bytes 2-3 should encode 3)
        uint256 len = L2ContractHelper.bytecodeLen(hash);
        assertEq(len, 3);
    }

    function test_hashL2Bytecode_maximumValidLength() public pure {
        // Maximum valid length is 2^16 - 1 words, but must be odd
        // Let's test with a smaller odd number that's still large
        bytes memory bytecode = new bytes(32 * 255); // 255 words (odd)

        bytes32 hash = L2ContractHelper.hashL2Bytecode(bytecode);

        uint256 len = L2ContractHelper.bytecodeLen(hash);
        assertEq(len, 255);
    }

    // ============ Fuzz Tests ============

    function testFuzz_bytecodeLen(uint8 byte2, uint8 byte3) public pure {
        // Construct a bytecode hash with specific length bytes
        bytes32 bytecodeHash = bytes32(
            (uint256(1) << 248) | // version = 1
                (uint256(byte2) << 232) | // length high byte
                (uint256(byte3) << 224) // length low byte
        );

        uint256 expectedLen = uint256(byte2) * 256 + uint256(byte3);
        uint256 actualLen = L2ContractHelper.bytecodeLen(bytecodeHash);

        assertEq(actualLen, expectedLen);
    }

    function testFuzz_computeCreateAddress(address sender, uint256 nonce) public pure {
        // Just verify it doesn't revert and produces deterministic results
        address addr1 = L2ContractHelper.computeCreateAddress(sender, nonce);
        address addr2 = L2ContractHelper.computeCreateAddress(sender, nonce);

        assertEq(addr1, addr2);
    }

    function testFuzz_computeCreate2Address(
        address sender,
        bytes32 salt,
        bytes32 bytecodeHash,
        bytes32 constructorInputHash
    ) public pure {
        // Just verify it doesn't revert and produces deterministic results
        address addr1 = L2ContractHelper.computeCreate2Address(sender, salt, bytecodeHash, constructorInputHash);
        address addr2 = L2ContractHelper.computeCreate2Address(sender, salt, bytecodeHash, constructorInputHash);

        assertEq(addr1, addr2);
    }

    function testFuzz_hashL2Bytecode_validOddWordCount(uint8 wordCountRaw) public pure {
        // Ensure odd word count between 1 and 255
        uint256 wordCount = (uint256(wordCountRaw) | 1); // Make odd
        if (wordCount == 0) wordCount = 1;
        if (wordCount > 255) wordCount = 255;

        bytes memory bytecode = new bytes(wordCount * 32);

        bytes32 hash = L2ContractHelper.hashL2Bytecode(bytecode);

        // Verify the hash has correct version
        assertEq(uint8(hash[0]), 1);
        // Verify length is encoded correctly
        assertEq(L2ContractHelper.bytecodeLen(hash), wordCount);
    }
}
