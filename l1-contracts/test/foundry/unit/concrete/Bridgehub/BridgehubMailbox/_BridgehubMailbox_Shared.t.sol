// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

/* solhint-disable max-line-length */

import {BridgehubTest} from "../_Bridgehub_Shared.t.sol";
import {IAllowList} from "../../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {IStateTransition} from "../../../../../../cache/solpp-generated-contracts/state-transition/IStateTransitionManager.sol";

/* solhint-enable max-line-length */

contract BridgehubMailboxTest is BridgehubTest {
    uint256 internal chainId;
    address internal chainStateTransition;
    address internal chainGovernor;
    IAllowList internal chainAllowList;

    constructor() {
        chainId = 987654321;
        chainStateTransition = makeAddr("chainStateTransition");
        chainGovernor = makeAddr("chainGovernor");
        chainAllowList = IAllowList(makeAddr("chainAllowList"));

        // vm.mockCall(
        //     bridgehub.getChainImplementation(),
        //     abi.encodeWithSelector(IBridgehubChain.initialize.selector),
        //     ""
        // );
        vm.mockCall(chainStateTransition, abi.encodeWithSelector(IStateTransitionManager.newChain.selector), "");

        vm.startPrank(GOVERNOR);
        bridgehub.addStateTransition(chainStateTransition);
        bridgehub.createNewChain(chainId, chainStateTransition, chainGovernor, chainAllowList, getDiamondCutData());
    }
}
