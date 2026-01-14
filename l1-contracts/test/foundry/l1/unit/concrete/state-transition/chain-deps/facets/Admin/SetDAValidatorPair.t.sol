// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized, InvalidL2DACommitmentScheme} from "contracts/common/L1ContractErrors.sol";
import {L1DAValidatorAddressIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";

contract SetDAValidatorPair is AdminTest {
    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.setDAValidatorPair(address(1), L2DACommitmentScheme.EMPTY_NO_DA);

        vm.stopPrank();
    }

    function test_SuccessfulSet() public {
        address admin = utilsFacet.util_getAdmin();

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit IAdmin.NewL1DAValidator(address(0), address(1));
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit IAdmin.NewL2DACommitmentScheme(L2DACommitmentScheme.NONE, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.startPrank(admin);
        adminFacet.setDAValidatorPair(address(1), L2DACommitmentScheme.EMPTY_NO_DA);

        assert(utilsFacet.util_getL2DACommimentScheme() == L2DACommitmentScheme.EMPTY_NO_DA);
    }

    function test_revertWhen_validatorAddressIsZero() public {
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        vm.expectRevert(L1DAValidatorAddressIsZero.selector);
        adminFacet.setDAValidatorPair(address(0), L2DACommitmentScheme.EMPTY_NO_DA);

        vm.stopPrank();
    }

    function test_revertWhen_l2CommitmentSchemeIsNone() public {
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidL2DACommitmentScheme.selector, L2DACommitmentScheme.NONE));
        adminFacet.setDAValidatorPair(address(1), L2DACommitmentScheme.NONE);

        vm.stopPrank();
    }
}
