// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {ValidiumL1DAValidator} from "../contracts/ValidiumL1DAValidator.sol";
import {L1DAValidatorOutput} from "../contracts/IL1DAValidator.sol";
import {Utils} from "./Utils.sol";

contract ValidiumL1DAValidatorTest is Test {
    ValidiumL1DAValidator internal validium;

    function setUp() public {
        validium = new ValidiumL1DAValidator();
    }

    function test_checkDARevert() public {
        bytes memory operatorDAInput = bytes("12");
        bytes32 l2DAValidatorOutputHash = Utils.randomBytes32("");
        vm.expectRevert("ValL1DA wrong input length");
        validium.checkDA(1, 1, l2DAValidatorOutputHash, operatorDAInput, 1);
    }

    function test_checkDA(bytes32 operatorDAInput) public {
        bytes memory input = abi.encode(operatorDAInput);
        console.log(operatorDAInput.length);
        L1DAValidatorOutput memory result = validium.checkDA(1, 1, Utils.randomBytes32(""), input, 1);

        assertEq(result.stateDiffHash, abi.decode(input, (bytes32)), "Invalid operator DA input");
    }
}
