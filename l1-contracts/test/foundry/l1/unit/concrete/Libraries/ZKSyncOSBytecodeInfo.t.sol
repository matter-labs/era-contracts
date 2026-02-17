// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";

/// @notice Wrapper contract to expose library functions
contract ZKSyncOSBytecodeInfoWrapper {
    function encodeZKSyncOSBytecodeInfo(
        bytes32 _bytecodeBlakeHash,
        uint32 _bytecodeLength,
        bytes32 _observableBytecodeHash
    ) external pure returns (bytes memory) {
        return
            ZKSyncOSBytecodeInfo.encodeZKSyncOSBytecodeInfo(
                _bytecodeBlakeHash,
                _bytecodeLength,
                _observableBytecodeHash
            );
    }

    function decodeZKSyncOSBytecodeInfo(bytes memory _bytecodeInfo) external pure returns (bytes32, uint32, bytes32) {
        return ZKSyncOSBytecodeInfo.decodeZKSyncOSBytecodeInfo(_bytecodeInfo);
    }
}

/// @notice Unit tests for ZKSyncOSBytecodeInfo library
contract ZKSyncOSBytecodeInfoTest is Test {
    ZKSyncOSBytecodeInfoWrapper internal wrapper;

    function setUp() public {
        wrapper = new ZKSyncOSBytecodeInfoWrapper();
    }

    // ============ encode Tests ============

    function test_encodeZKSyncOSBytecodeInfo_basicValues() public view {
        bytes32 blakeHash = bytes32(uint256(0x1234));
        uint32 length = 1000;
        bytes32 keccakHash = bytes32(uint256(0x5678));

        bytes memory encoded = wrapper.encodeZKSyncOSBytecodeInfo(blakeHash, length, keccakHash);

        // Check that it's properly encoded
        assertTrue(encoded.length > 0, "Encoded data should not be empty");

        // Decode and verify
        (bytes32 decodedBlake, uint32 decodedLength, bytes32 decodedKeccak) = abi.decode(
            encoded,
            (bytes32, uint32, bytes32)
        );
        assertEq(decodedBlake, blakeHash);
        assertEq(decodedLength, length);
        assertEq(decodedKeccak, keccakHash);
    }

    function test_encodeZKSyncOSBytecodeInfo_zeroValues() public view {
        bytes memory encoded = wrapper.encodeZKSyncOSBytecodeInfo(bytes32(0), 0, bytes32(0));

        (bytes32 decodedBlake, uint32 decodedLength, bytes32 decodedKeccak) = abi.decode(
            encoded,
            (bytes32, uint32, bytes32)
        );
        assertEq(decodedBlake, bytes32(0));
        assertEq(decodedLength, 0);
        assertEq(decodedKeccak, bytes32(0));
    }

    function test_encodeZKSyncOSBytecodeInfo_maxValues() public view {
        bytes32 maxHash = bytes32(type(uint256).max);
        uint32 maxLength = type(uint32).max;

        bytes memory encoded = wrapper.encodeZKSyncOSBytecodeInfo(maxHash, maxLength, maxHash);

        (bytes32 decodedBlake, uint32 decodedLength, bytes32 decodedKeccak) = abi.decode(
            encoded,
            (bytes32, uint32, bytes32)
        );
        assertEq(decodedBlake, maxHash);
        assertEq(decodedLength, maxLength);
        assertEq(decodedKeccak, maxHash);
    }

    // ============ decode Tests ============

    function test_decodeZKSyncOSBytecodeInfo_basicValues() public view {
        bytes32 blakeHash = bytes32(uint256(0xabcd));
        uint32 length = 5000;
        bytes32 keccakHash = bytes32(uint256(0xef01));

        bytes memory encoded = abi.encode(blakeHash, length, keccakHash);

        (bytes32 decodedBlake, uint32 decodedLength, bytes32 decodedKeccak) = wrapper.decodeZKSyncOSBytecodeInfo(
            encoded
        );

        assertEq(decodedBlake, blakeHash);
        assertEq(decodedLength, length);
        assertEq(decodedKeccak, keccakHash);
    }

    // ============ Roundtrip Tests ============

    function test_roundtrip_encodeDecodeZKSyncOSBytecodeInfo() public view {
        bytes32 blakeHash = keccak256("blake hash test");
        uint32 length = 12345;
        bytes32 keccakHash = keccak256("keccak hash test");

        bytes memory encoded = wrapper.encodeZKSyncOSBytecodeInfo(blakeHash, length, keccakHash);
        (bytes32 decodedBlake, uint32 decodedLength, bytes32 decodedKeccak) = wrapper.decodeZKSyncOSBytecodeInfo(
            encoded
        );

        assertEq(decodedBlake, blakeHash);
        assertEq(decodedLength, length);
        assertEq(decodedKeccak, keccakHash);
    }

    // ============ Fuzz Tests ============

    function testFuzz_roundtrip_encodeDecodeZKSyncOSBytecodeInfo(
        bytes32 blakeHash,
        uint32 length,
        bytes32 keccakHash
    ) public view {
        bytes memory encoded = wrapper.encodeZKSyncOSBytecodeInfo(blakeHash, length, keccakHash);
        (bytes32 decodedBlake, uint32 decodedLength, bytes32 decodedKeccak) = wrapper.decodeZKSyncOSBytecodeInfo(
            encoded
        );

        assertEq(decodedBlake, blakeHash);
        assertEq(decodedLength, length);
        assertEq(decodedKeccak, keccakHash);
    }
}
