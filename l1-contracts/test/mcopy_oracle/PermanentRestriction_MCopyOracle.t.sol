// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";

contract PermanentRestriction_MCopyOracle is Test {
    function _mcopy(bytes memory src, uint256 srcOffset, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        assembly {
            mcopy(add(out, 0x20), add(add(src, 0x20), srcOffset), len)
        }
    }

    function _callCopy(bytes memory src, uint256 srcOffset, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        // inline the same logic used by _copyBytes helper
        assembly {
            let dstPtr := add(out, 0x20)
            let srcPtr := add(add(src, 0x20), srcOffset)
            let chunks := and(len, not(31))
            for {
                let i := 0
            } lt(i, chunks) {
                i := add(i, 0x20)
            } {
                mstore(add(dstPtr, i), mload(add(srcPtr, i)))
            }
            let rem := and(len, 31)
            if rem {
                let tailDst := add(dstPtr, chunks)
                let tailSrc := add(srcPtr, chunks)
                let remBits := shl(3, rem)
                let keepMask := shr(remBits, not(0))
                let keep := and(mload(tailDst), keepMask)
                let put := and(mload(tailSrc), not(keepMask))
                mstore(tailDst, or(put, keep))
            }
        }
    }

    function test_fuzz_copy_matches_mcopy(bytes memory data, uint128 start16) public {
        uint256 start = uint256(start16) % (data.length == 0 ? 1 : data.length);
        uint256 len = data.length - start;
        bytes memory a = _callCopy(data, start, len);
        bytes memory b = _mcopy(data, start, len);
        assertEq(a, b, "_copyBytes != mcopy");
    }
}
