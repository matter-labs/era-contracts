// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";

/// @notice Unit tests for InteropDataEncoding library
contract InteropDataEncodingTest is Test {
    // ============ encodeInteropBundleHash Tests ============

    function test_encodeInteropBundleHash_basicEncoding() public pure {
        uint256 sourceChainId = 1;
        bytes memory bundle = hex"1234567890";

        bytes32 result = InteropDataEncoding.encodeInteropBundleHash(sourceChainId, bundle);

        bytes32 expected = keccak256(abi.encode(sourceChainId, bundle));
        assertEq(result, expected);
    }

    function test_encodeInteropBundleHash_emptyBundle() public pure {
        uint256 sourceChainId = 1;
        bytes memory bundle = "";

        bytes32 result = InteropDataEncoding.encodeInteropBundleHash(sourceChainId, bundle);

        bytes32 expected = keccak256(abi.encode(sourceChainId, bundle));
        assertEq(result, expected);
    }

    function test_encodeInteropBundleHash_differentChainIds() public pure {
        bytes memory bundle = hex"deadbeef";

        bytes32 result1 = InteropDataEncoding.encodeInteropBundleHash(1, bundle);
        bytes32 result2 = InteropDataEncoding.encodeInteropBundleHash(2, bundle);

        assertTrue(result1 != result2);
    }

    function test_encodeInteropBundleHash_differentBundles() public pure {
        uint256 sourceChainId = 1;

        bytes32 result1 = InteropDataEncoding.encodeInteropBundleHash(sourceChainId, hex"1111");
        bytes32 result2 = InteropDataEncoding.encodeInteropBundleHash(sourceChainId, hex"2222");

        assertTrue(result1 != result2);
    }

    function test_encodeInteropBundleHash_largeBundle() public pure {
        uint256 sourceChainId = 42;
        bytes memory largeBundle = new bytes(10000);
        for (uint256 i = 0; i < 10000; i++) {
            largeBundle[i] = bytes1(uint8(i % 256));
        }

        bytes32 result = InteropDataEncoding.encodeInteropBundleHash(sourceChainId, largeBundle);

        bytes32 expected = keccak256(abi.encode(sourceChainId, largeBundle));
        assertEq(result, expected);
    }

    function test_encodeInteropBundleHash_maxChainId() public pure {
        uint256 sourceChainId = type(uint256).max;
        bytes memory bundle = hex"cafe";

        bytes32 result = InteropDataEncoding.encodeInteropBundleHash(sourceChainId, bundle);

        bytes32 expected = keccak256(abi.encode(sourceChainId, bundle));
        assertEq(result, expected);
    }

    function test_encodeInteropBundleHash_zeroChainId() public pure {
        uint256 sourceChainId = 0;
        bytes memory bundle = hex"babe";

        bytes32 result = InteropDataEncoding.encodeInteropBundleHash(sourceChainId, bundle);

        bytes32 expected = keccak256(abi.encode(sourceChainId, bundle));
        assertEq(result, expected);
    }

    // ============ Fuzz Tests ============

    function testFuzz_encodeInteropBundleHash(uint256 sourceChainId, bytes memory bundle) public pure {
        bytes32 result = InteropDataEncoding.encodeInteropBundleHash(sourceChainId, bundle);

        bytes32 expected = keccak256(abi.encode(sourceChainId, bundle));
        assertEq(result, expected);
    }

    function testFuzz_encodeInteropBundleHash_uniqueness(
        uint256 chainId1,
        uint256 chainId2,
        bytes memory bundle
    ) public pure {
        vm.assume(chainId1 != chainId2);

        bytes32 result1 = InteropDataEncoding.encodeInteropBundleHash(chainId1, bundle);
        bytes32 result2 = InteropDataEncoding.encodeInteropBundleHash(chainId2, bundle);

        assertTrue(result1 != result2);
    }
}
