// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice Unit tests for SemVer library
contract SemVerTest is Test {
    // ============ packSemVer Tests ============

    function test_packSemVer_zeroVersion() public pure {
        uint96 packed = SemVer.packSemVer(0, 0, 0);
        assertEq(packed, 0);
    }

    function test_packSemVer_onlyPatch() public pure {
        uint96 packed = SemVer.packSemVer(0, 0, 123);
        assertEq(packed, 123);
    }

    function test_packSemVer_onlyMinor() public pure {
        uint96 packed = SemVer.packSemVer(0, 42, 0);
        // minor is shifted left by 32 bits
        assertEq(packed, uint96(42) << 32);
    }

    function test_packSemVer_onlyMajor() public pure {
        uint96 packed = SemVer.packSemVer(7, 0, 0);
        // major is shifted left by 64 bits
        assertEq(packed, uint96(7) << 64);
    }

    function test_packSemVer_allComponents() public pure {
        uint32 major = 1;
        uint32 minor = 2;
        uint32 patch = 3;

        uint96 packed = SemVer.packSemVer(major, minor, patch);

        uint96 expected = uint96(patch) | (uint96(minor) << 32) | (uint96(major) << 64);
        assertEq(packed, expected);
    }

    function test_packSemVer_maxValues() public pure {
        uint32 maxU32 = type(uint32).max;
        uint96 packed = SemVer.packSemVer(maxU32, maxU32, maxU32);

        // This should fit in uint96 since 3 * 32 = 96 bits
        uint96 expected = uint96(maxU32) | (uint96(maxU32) << 32) | (uint96(maxU32) << 64);
        assertEq(packed, expected);
    }

    // ============ unpackSemVer Tests ============

    function test_unpackSemVer_zeroVersion() public pure {
        (uint32 major, uint32 minor, uint32 patch) = SemVer.unpackSemVer(0);
        assertEq(major, 0);
        assertEq(minor, 0);
        assertEq(patch, 0);
    }

    function test_unpackSemVer_onlyPatch() public pure {
        uint96 packed = 456;
        (uint32 major, uint32 minor, uint32 patch) = SemVer.unpackSemVer(packed);
        assertEq(major, 0);
        assertEq(minor, 0);
        assertEq(patch, 456);
    }

    function test_unpackSemVer_onlyMinor() public pure {
        uint96 packed = uint96(789) << 32;
        (uint32 major, uint32 minor, uint32 patch) = SemVer.unpackSemVer(packed);
        assertEq(major, 0);
        assertEq(minor, 789);
        assertEq(patch, 0);
    }

    function test_unpackSemVer_onlyMajor() public pure {
        uint96 packed = uint96(12) << 64;
        (uint32 major, uint32 minor, uint32 patch) = SemVer.unpackSemVer(packed);
        assertEq(major, 12);
        assertEq(minor, 0);
        assertEq(patch, 0);
    }

    function test_unpackSemVer_allComponents() public pure {
        uint96 packed = uint96(5) | (uint96(10) << 32) | (uint96(15) << 64);
        (uint32 major, uint32 minor, uint32 patch) = SemVer.unpackSemVer(packed);
        assertEq(major, 15);
        assertEq(minor, 10);
        assertEq(patch, 5);
    }

    function test_unpackSemVer_maxValues() public pure {
        uint32 maxU32 = type(uint32).max;
        uint96 packed = uint96(maxU32) | (uint96(maxU32) << 32) | (uint96(maxU32) << 64);
        (uint32 major, uint32 minor, uint32 patch) = SemVer.unpackSemVer(packed);
        assertEq(major, maxU32);
        assertEq(minor, maxU32);
        assertEq(patch, maxU32);
    }

    // ============ Roundtrip Tests ============

    function test_roundtrip_packUnpack() public pure {
        uint32 major = 0;
        uint32 minor = 29;
        uint32 patch = 1;

        uint96 packed = SemVer.packSemVer(major, minor, patch);
        (uint32 unpackedMajor, uint32 unpackedMinor, uint32 unpackedPatch) = SemVer.unpackSemVer(packed);

        assertEq(unpackedMajor, major);
        assertEq(unpackedMinor, minor);
        assertEq(unpackedPatch, patch);
    }

    // ============ Fuzz Tests ============

    function testFuzz_roundtrip_packUnpack(uint32 major, uint32 minor, uint32 patch) public pure {
        uint96 packed = SemVer.packSemVer(major, minor, patch);
        (uint32 unpackedMajor, uint32 unpackedMinor, uint32 unpackedPatch) = SemVer.unpackSemVer(packed);

        assertEq(unpackedMajor, major);
        assertEq(unpackedMinor, minor);
        assertEq(unpackedPatch, patch);
    }

    function testFuzz_packSemVer_deterministicOutput(uint32 major, uint32 minor, uint32 patch) public pure {
        uint96 packed1 = SemVer.packSemVer(major, minor, patch);
        uint96 packed2 = SemVer.packSemVer(major, minor, patch);
        assertEq(packed1, packed2);
    }

    function testFuzz_unpackSemVer_deterministicOutput(uint96 packed) public pure {
        (uint32 major1, uint32 minor1, uint32 patch1) = SemVer.unpackSemVer(packed);
        (uint32 major2, uint32 minor2, uint32 patch2) = SemVer.unpackSemVer(packed);

        assertEq(major1, major2);
        assertEq(minor1, minor2);
        assertEq(patch1, patch2);
    }
}
