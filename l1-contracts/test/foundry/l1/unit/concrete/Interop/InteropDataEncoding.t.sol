// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";

/// @notice Unit tests for InteropDataEncoding library.
/// @dev `encodeInteropBundleHash` is `keccak256(_bundle)`: the bundle bytes already commit the bundle's own
/// `sourceChainId`, so it is not mixed in separately. These tests pin that exact formula and its determinism.
contract InteropDataEncodingTest is Test {
    // ============ encodeInteropBundleHash Tests ============

    function test_encodeInteropBundleHash_basicEncoding() public pure {
        bytes memory bundle = hex"1234567890";

        bytes32 result = InteropDataEncoding.encodeInteropBundleHash(bundle);

        assertEq(result, keccak256(bundle));
    }

    function test_encodeInteropBundleHash_emptyBundle() public pure {
        bytes memory bundle = "";

        bytes32 result = InteropDataEncoding.encodeInteropBundleHash(bundle);

        assertEq(result, keccak256(bundle));
    }

    function test_encodeInteropBundleHash_deterministic() public pure {
        bytes memory bundle = hex"deadbeef";

        bytes32 result1 = InteropDataEncoding.encodeInteropBundleHash(bundle);
        bytes32 result2 = InteropDataEncoding.encodeInteropBundleHash(bundle);

        assertEq(result1, result2, "same bundle must hash identically");
    }

    function test_encodeInteropBundleHash_differentBundles() public pure {
        bytes32 result1 = InteropDataEncoding.encodeInteropBundleHash(hex"1111");
        bytes32 result2 = InteropDataEncoding.encodeInteropBundleHash(hex"2222");

        assertTrue(result1 != result2);
    }

    function test_encodeInteropBundleHash_largeBundle() public pure {
        bytes memory largeBundle = new bytes(10000);
        for (uint256 i = 0; i < 10000; i++) {
            largeBundle[i] = bytes1(uint8(i % 256));
        }

        bytes32 result = InteropDataEncoding.encodeInteropBundleHash(largeBundle);

        assertEq(result, keccak256(largeBundle));
    }

    // ============ Fuzz Tests ============

    function testFuzz_encodeInteropBundleHash(bytes memory bundle) public pure {
        bytes32 result = InteropDataEncoding.encodeInteropBundleHash(bundle);

        assertEq(result, keccak256(bundle));
    }

    /// @dev Distinct bundle bytes (whatever their embedded sourceChainId) must yield distinct hashes.
    function testFuzz_encodeInteropBundleHash_uniqueness(bytes memory bundleA, bytes memory bundleB) public pure {
        vm.assume(keccak256(bundleA) != keccak256(bundleB));

        assertTrue(
            InteropDataEncoding.encodeInteropBundleHash(bundleA) != InteropDataEncoding.encodeInteropBundleHash(bundleB)
        );
    }
}
