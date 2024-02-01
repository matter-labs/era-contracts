// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER} from "../ZkSyncStateTransitionBase/_ZkSyncStateTransitionBase_Shared.t.sol";

import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {IStateTransitionManager} from "solpp/state-transition/IStateTransitionManager.sol";

contract UpgradeChainFromVersionTest is AdminTest {
    event ExecuteUpgrade(Diamond.DiamondCutData diamondCut);

    function test_revertWhen_calledByNonGovernorOrStateTransitionManager() public {
        address nonGovernorOrStateTransitionManager = makeAddr("nonGovernorOrStateTransitionManager");
        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        vm.expectRevert(ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER);

        vm.startPrank(nonGovernorOrStateTransitionManager);
        adminFacet.upgradeChainFromVersion(oldProtocolVersion, diamondCutData);
    }

    function test_revertWhen_cutHashMismatch() public {
        address governor = utilsFacet.util_getGovernor();
        address stateTransitionManager = makeAddr("stateTransitionManager");

        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        utilsFacet.util_setStateTransitionManager(stateTransitionManager);

        bytes32 cutHashInput = keccak256("random");
        vm.mockCall(
            stateTransitionManager,
            abi.encodeWithSelector(IStateTransitionManager.upgradeCutHash.selector),
            abi.encode(cutHashInput)
        );

        vm.expectRevert("StateTransition: cutHash mismatch");

        vm.startPrank(governor);
        adminFacet.upgradeChainFromVersion(oldProtocolVersion, diamondCutData);
    }

    function test_revertWhen_ProtocolVersionMismatchWhenUpgrading() public {
        address governor = utilsFacet.util_getGovernor();
        address stateTransitionManager = makeAddr("stateTransitionManager");

        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        utilsFacet.util_setProtocolVersion(oldProtocolVersion + 1);
        utilsFacet.util_setStateTransitionManager(stateTransitionManager);

        bytes32 cutHashInput = keccak256(abi.encode(diamondCutData));
        vm.mockCall(
            stateTransitionManager,
            abi.encodeWithSelector(IStateTransitionManager.upgradeCutHash.selector),
            abi.encode(cutHashInput)
        );

        vm.expectRevert("StateTransition: protocolVersion mismatch in STC when upgrading");

        vm.startPrank(governor);
        adminFacet.upgradeChainFromVersion(oldProtocolVersion, diamondCutData);
    }

    function test_revertWhen_ProtocolVersionMismatchAfterUpgrading() public {
        address governor = utilsFacet.util_getGovernor();
        address stateTransitionManager = makeAddr("stateTransitionManager");

        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: new bytes(0)
        });

        utilsFacet.util_setProtocolVersion(oldProtocolVersion);
        utilsFacet.util_setStateTransitionManager(stateTransitionManager);

        bytes32 cutHashInput = keccak256(abi.encode(diamondCutData));
        vm.mockCall(
            stateTransitionManager,
            abi.encodeWithSelector(IStateTransitionManager.upgradeCutHash.selector),
            abi.encode(cutHashInput)
        );

        vm.expectRevert("StateTransition: protocolVersion mismatch in STC after upgrading");

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit ExecuteUpgrade(diamondCutData);

        vm.startPrank(governor);
        adminFacet.upgradeChainFromVersion(oldProtocolVersion, diamondCutData);
    }

    // TODO
    // function test_successfulUpgrade() public {}
}
