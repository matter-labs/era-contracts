// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ValidiumL2DAValidator} from "contracts/data-availability/ValidiumL2DAValidator.sol";

contract L2ValidiumDAValidatorTest is Test {
    function test_callValidiumDAValidator(address depositor, address receiver, uint256 amount) internal {
        ValidiumL2DAValidator validator = new ValidiumL2DAValidator();

        bytes32 outputHash = validator.validatePubdata(bytes32(0), bytes32(0), bytes32(0), bytes32(0), hex"");

        assertEq(outputHash, bytes32(0));
    }
}
