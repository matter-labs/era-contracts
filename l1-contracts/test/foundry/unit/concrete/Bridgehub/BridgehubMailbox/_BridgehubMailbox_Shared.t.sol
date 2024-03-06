// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubTest} from "../_Bridgehub_Shared.t.sol";
import {IStateTransitionManager} from "solpp/state-transition/IStateTransitionManager.sol";

contract BridgehubMailboxTest is BridgehubTest {
    uint256 internal chainId;
    address internal chainStateTransition;
    address internal chainGovernor;

    // constructor() {
    //     chainId = 987654321;
    //     chainStateTransition = makeAddr("chainStateTransition");
    //     chainGovernor = makeAddr("chainGovernor");
    //     // vm.mockCall(
    //     //     bridgehub.getChainImplementation(),
    //     //     abi.encodeWithSelector(IBridgehubChain.initialize.selector),
    //     //     ""
    //     // );
    //     vm.mockCall(chainStateTransition, abi.encodeWithSelector(IStateTransitionManager.newChain.selector), "");
    //     vm.startPrank(GOVERNOR);
    //     bridgehub.addStateTransition(chainStateTransition);
    //     bridgehub.createNewChain(chainId, chainStateTransition, chainGovernor, getDiamondCutData());
    // }
}
