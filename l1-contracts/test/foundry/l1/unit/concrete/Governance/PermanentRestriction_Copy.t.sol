// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

contract PermanentRestrictionHarness is PermanentRestriction {
    constructor(address bridgehub, address l2AdminFactory)
        PermanentRestriction(IBridgehub(bridgehub), l2AdminFactory)
    {}

    function copyNew(bytes memory src, uint256 srcOffset, uint256 len) external pure returns (bytes memory out) {
        out = new bytes(len);
        _copyBytes(out, 0, src, srcOffset, len);
    }
}

contract PermanentRestriction_CopyTest is Test {
    PermanentRestrictionHarness private harness;

    function setUp() public {
        harness = new PermanentRestrictionHarness(address(0xdead), address(0xbeef));
    }

    function _reference(bytes memory src, uint256 srcOffset, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        assembly {
            let dst := add(out, 0x20)
            let s := add(add(src, 0x20), srcOffset)
            let chunks := and(len, not(31))
            for { let i := 0 } lt(i, chunks) { i := add(i, 0x20) } {
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

    function test_copy_matches_reference() public {
        bytes memory src = new bytes(123);
        for (uint256 i = 0; i < src.length; i++) src[i] = bytes1(uint8(i));
        for (uint256 start = 0; start < src.length; start += 7) {
            uint256 len = src.length - start;
            bytes memory out = harness.copyNew(src, start, len);
            bytes memory ref = _reference(src, start, len);
            assertEq(out, ref);
        }
    }

    function test_fuzz_copy(bytes memory src, uint128 start16) public {
        uint256 start = uint256(start16) % (src.length == 0 ? 1 : src.length);
        uint256 len = src.length - start;
        bytes memory out = harness.copyNew(src, start, len);
        bytes memory ref = _reference(src, start, len);
        assertEq(out, ref);
    }
}


