// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {InvalidPubdataPricingMode, Unauthorized} from "contracts/common/L1ContractErrors.sol";
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

    /// @dev The pubdata pricing mode (Rollup vs Validium) may only be changed before the first batch is
    /// committed. After a batch exists, flipping it would desync the DA accounting of already-committed
    /// batches, so the call must revert.
    function test_revertWhen_batchesAlreadyCommitted() public {
        address admin = utilsFacet.util_getAdmin();
        utilsFacet.util_setTotalBatchesCommitted(1);

        vm.prank(admin);
        vm.expectRevert(InvalidPubdataPricingMode.selector);
        adminFacet.setPubdataPricingMode(PubdataPricingMode.Validium);
    }
}
