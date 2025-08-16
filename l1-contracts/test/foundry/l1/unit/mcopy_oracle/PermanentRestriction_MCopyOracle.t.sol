// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

contract PermanentRestrictionHarness is PermanentRestriction {
    constructor() PermanentRestriction(IBridgehub(address(0)), address(0)) {}

    function copyNew(bytes memory src, uint256 srcOffset, uint256 len) external pure returns (bytes memory out) {
        out = new bytes(len);
        _copyBytes({ dest: out, destOffset: 0, src: src, srcOffset: srcOffset, len: len });
    }
}

contract PermanentRestriction_MCopyOracle is Test {
    PermanentRestrictionHarness private harness;

    function setUp() public {
        harness = new PermanentRestrictionHarness();
    }

    function _mcopy(bytes memory src, uint256 srcOffset, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        assembly {
            mcopy(add(out, 0x20), add(add(src, 0x20), srcOffset), len)
        }
    }

    function test_fuzz_copy_matches_mcopy(bytes memory data, uint128 start16) public {
        uint256 start = uint256(start16) % (data.length == 0 ? 1 : data.length);
        uint256 len = data.length - start;
        bytes memory a = harness.copyNew(data, start, len);
        bytes memory b = _mcopy(data, start, len);
        assertEq(a, b, "_copyBytes != mcopy");
    }
}
