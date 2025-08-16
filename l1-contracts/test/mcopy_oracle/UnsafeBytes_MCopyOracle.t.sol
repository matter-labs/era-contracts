// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UnsafeBytes} from "contracts/common/libraries/UnsafeBytes.sol";

contract UnsafeBytes_MCopyOracle is Test {
    function _mcopy(bytes memory src, uint256 srcOffset, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        assembly {
            mcopy(add(out, 0x20), add(add(src, 0x20), srcOffset), len)
        }
    }

    function test_fuzz_readRemainingBytes_matches_mcopy(bytes memory data, uint128 start16) public {
        uint256 start = uint256(start16) % (data.length == 0 ? 1 : data.length);
        bytes memory a = UnsafeBytes.readRemainingBytes(data, start);
        bytes memory b = _mcopy(data, start, data.length - start);
        assertEq(a, b, "readRemainingBytes != mcopy");
    }
}


