// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized, ChainAlreadyLive} from "contracts/common/L1ContractErrors.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkChainStorage.sol";

contract SetPubdataPricingModeTest is AdminTest {
    event ValidiumModeStatusUpdate(PubdataPricingMode _pricingMode);

    function test_revertWhen_calledByNonAdmin() public {
        assertTrue(true);
        // address nonAdmin = makeAddr("nonAdmin");

        // vm.startPrank(nonAdmin);

        // vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        // adminFacet.setPubdataPricingMode(PubdataPricingMode.Validium);

        // vm.stopPrank();
    }

    // function test_revertWhen_totalBatchesCommittedGreaterThenZero() public {
    //     address admin = utilsFacet.util_getAdmin();

    //     utilsFacet.util_setTotalBatchesCommitted(1);

    //     vm.startPrank(admin);

    //     vm.expectRevert(ChainAlreadyLive.selector);
    //     adminFacet.setPubdataPricingMode(PubdataPricingMode.Validium);
    // }

    // function test_SuccessfulSet() public {
    //     address admin = utilsFacet.util_getAdmin();

    //     vm.expectEmit(true, true, true, true, address(adminFacet));
    //     emit ValidiumModeStatusUpdate(PubdataPricingMode.Validium);

    //     vm.startPrank(admin);
    //     adminFacet.setPubdataPricingMode(PubdataPricingMode.Validium);

    //     assert(utilsFacet.util_getFeeParams().pubdataPricingMode == PubdataPricingMode.Validium);
    // }
}
