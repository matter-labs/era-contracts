// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Utils as ScriptUtils} from "deploy-scripts/Utils.sol";

contract ScriptUtilsTest is Test {
    function test_Blake2s256Hash() public {
        bytes32 testHash = ScriptUtils.blakeHashBytecode(bytes("hello world"));

        assert(testHash == 0x9aec6806794561107e594b1f6a8a6b0c92a0cba9acf5e5e93cca06f781813b0b);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
