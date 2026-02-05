// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {RestrictionValidator} from "contracts/governance/restriction/RestrictionValidator.sol";
import {IRestriction, RESTRICTION_MAGIC} from "contracts/governance/restriction/IRestriction.sol";
import {NotARestriction} from "contracts/common/L1ContractErrors.sol";
import {DummyRestriction} from "contracts/dev-contracts/DummyRestriction.sol";

/// @notice Wrapper contract to expose library function
contract RestrictionValidatorWrapper {
    function validateRestriction(address _restriction) external view {
        RestrictionValidator.validateRestriction(_restriction);
    }
}

/// @notice A contract that doesn't implement the restriction interface
contract NotARestrictionContract {
    function getSupportsRestrictionMagic() external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Unit tests for RestrictionValidator library
contract RestrictionValidatorTest is Test {
    RestrictionValidatorWrapper internal validator;
    DummyRestriction internal validRestriction;
    NotARestrictionContract internal invalidRestriction;

    function setUp() public {
        validator = new RestrictionValidatorWrapper();
        validRestriction = new DummyRestriction(true);
        invalidRestriction = new NotARestrictionContract();
    }

    function test_validateRestriction_succeedsForValidRestriction() public view {
        // Should not revert
        validator.validateRestriction(address(validRestriction));
    }

    function test_validateRestriction_revertsForInvalidRestriction() public {
        vm.expectRevert(abi.encodeWithSelector(NotARestriction.selector, address(invalidRestriction)));
        validator.validateRestriction(address(invalidRestriction));
    }

    function test_validateRestriction_revertsForNonContract() public {
        address notAContract = makeAddr("notAContract");
        vm.expectRevert(); // Will revert because there's no code at the address
        validator.validateRestriction(notAContract);
    }

    function test_validateRestriction_revertsForIncorrectMagic() public {
        // DummyRestriction with isValid=false returns wrong magic
        DummyRestriction invalidMagicRestriction = new DummyRestriction(false);

        vm.expectRevert(abi.encodeWithSelector(NotARestriction.selector, address(invalidMagicRestriction)));
        validator.validateRestriction(address(invalidMagicRestriction));
    }
}
