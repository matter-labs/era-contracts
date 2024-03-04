// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {ERROR_ONLY_STATE_TRANSITION_MANAGER} from "../Base/_Base_Shared.t.sol";

import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";

contract ExecuteUpgradeTest is AdminTest {
    event ExecuteUpgrade(Diamond.DiamondCutData diamondCut);

    function test_revertWhen_calledByNonGovernorOrStateTransitionManager() public {
        address nonStateTransitionManager = makeAddr("nonStateTransitionManager");
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        vm.expectRevert(ERROR_ONLY_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonStateTransitionManager);
        adminFacet.executeUpgrade(diamondCutData);
    }

    // TODO
    // function test_successfulUpgrade() public {
    // address stateTransitionManager = utilsFacet.util_getStateTransitionManager();
    // Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
    //     facetCuts: new Diamond.FacetCut[](0),
    //     initAddress: address(0),
    //     initCalldata: new bytes(0)
    // });
    // vm.mockCall(address(0), abi.encodeWithSelector(IDiamondLibrary.diamondCut.selector), abi.encode());
    // vm.expectEmit(true, true, true, true, address(adminFacet));
    // emit ExecuteUpgrade(diamondCutData);
    // vm.startPrank(stateTransitionManager);
    // adminFacet.executeUpgrade(diamondCutData);
    // }
}

interface IDiamondLibrary {
    function diamondCut(Diamond.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata) external;
}
