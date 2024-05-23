// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {ERROR_ONLY_ADMIN} from "../Base/_Base_Shared.t.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";

contract SetPubdataPricingModeTest is AdminTest {
    event ValidiumModeStatusUpdate(PubdataPricingMode _pricingMode);

    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);
        vm.expectRevert(ERROR_ONLY_ADMIN);

        adminFacet.setPubdataPricingMode(PubdataPricingMode.Validium);
    }

    function test_revertWhen_totalBatchesCommittedGreaterThenZero() public {
        address admin = utilsFacet.util_getAdmin();

        utilsFacet.util_setTotalBatchesCommitted(1);

        vm.startPrank(admin);

        vm.expectRevert(bytes.concat("AdminFacet: set validium only after genesis"));
        adminFacet.setPubdataPricingMode(PubdataPricingMode.Validium);
    }

    function test_SuccessfulSet() public {
        address admin = utilsFacet.util_getAdmin();

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ValidiumModeStatusUpdate(PubdataPricingMode.Validium);

        vm.startPrank(admin);
        adminFacet.setPubdataPricingMode(PubdataPricingMode.Validium);

        assert(utilsFacet.util_getFeeParams().pubdataPricingMode == PubdataPricingMode.Validium);
    }
}
