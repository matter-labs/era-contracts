// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized, ChainAlreadyLive} from "contracts/common/L1ContractErrors.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";

contract SetPubdataPricingModeTest is AdminTest {
    event PubdataPricingModeUpdate(PubdataPricingMode _pricingMode);

    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.setPubdataPricingMode(PubdataPricingMode.Validium);

        vm.stopPrank();
    }

    function test_SuccessfulSet() public {
        address admin = utilsFacet.util_getAdmin();

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit PubdataPricingModeUpdate(PubdataPricingMode.Validium);

        vm.startPrank(admin);
        adminFacet.setPubdataPricingMode(PubdataPricingMode.Validium);

        assert(utilsFacet.util_getFeeParams().pubdataPricingMode == PubdataPricingMode.Validium);
    }
}
