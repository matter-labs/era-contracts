// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract ExecuteUpgradeTest is AdminTest {
    event ExecuteUpgrade(Diamond.DiamondCutData diamondCut);

    function test_revertWhen_calledByNonGovernorOrChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));

        vm.startPrank(nonChainTypeManager);
        adminFacet.executeUpgrade(diamondCutData);
    }
}

interface IDiamondLibrary {
    function diamondCut(Diamond.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata) external;
}
