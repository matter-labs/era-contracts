// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubChainTest} from "./_BridgehubChain_Shared.t.sol";
import {IAllowList} from "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {BridgehubChain} from "../../../../../cache/solpp-generated-contracts/bridgehub/BridgehubChain.sol";

contract InitializeTest is BridgehubChainTest {
    function setUp() public {
        bridgehubChain = new BridgehubChain();

        chainId = 838383838383;
        stateTransition = makeAddr("stateTransition");
        governor = makeAddr("governor");
        allowList = IAllowList(makeAddr("owner"));
        priorityTxMaxGasLimit = 99999;
    }

    function test_RevertWhen_GovernorIsZeroAddress() public {
        governor = address(0);

        vm.expectRevert(bytes.concat("vy"));
        bridgehubChain.initialize(chainId, stateTransition, governor, allowList, priorityTxMaxGasLimit);
    }

    function test_InitializeSuccessfully() public {
        bridgehubChain.initialize(chainId, stateTransition, governor, allowList, priorityTxMaxGasLimit);

        assertEq(bridgehubChain.getChainId(), chainId);
        assertEq(bridgehubChain.getStateTransition(), stateTransition);
        assertEq(bridgehubChain.getGovernor(), governor);
        assertEq(address(bridgehubChain.getAllowList()), address(allowList));
        assertEq(bridgehubChain.getPriorityTxMaxGasLimit(), priorityTxMaxGasLimit);
    }
}
