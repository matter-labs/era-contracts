// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubTest} from "./_Bridgehub_Shared.t.sol";
import {IAllowList} from "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
// import {DiamondProxy} from "../../../../../cache/solpp-generated-contracts/common/DiamondProxy.sol";
import {BridgehubDiamondInit} from "../../../../../cache/solpp-generated-contracts/bridgehub/bridgehub-deps/BridgehubDiamondInit.sol";

contract InitializeTest is BridgehubTest {
    address internal governor;
    address internal chainImplementation;
    address internal chainProxyAdmin;
    IAllowList internal allowList;
    uint256 internal priorityTxMaxGasLimit;

    function setUp() public {
        bridgehubDiamondInit = new BridgehubDiamondInit();

        governor = GOVERNOR;
        chainImplementation = makeAddr("chainImplementation");
        chainProxyAdmin = makeAddr("chainProxyAdmin");
        allowList = IAllowList(makeAddr("owner"));
        priorityTxMaxGasLimit = 1090193;
    }

    // function test_RevertWhen_AlreadyInitialized() public {
    //     bridgehub.initialize(governor, chainImplementation, chainProxyAdmin, allowList, priorityTxMaxGasLimit);

    //     vm.expectRevert(bytes.concat("bridgehub1"));
    //     bridgehub.initialize(governor, chainImplementation, chainProxyAdmin, allowList, priorityTxMaxGasLimit);
    // }

    // function test_InitializeSuccessfully() public {
    //     bridgehub.initialize(governor, chainImplementation, chainProxyAdmin, allowList, priorityTxMaxGasLimit);

    //     assertEq(bridgehub.governor(), governor);
    //     assertEq(bridgehub.getChainImplementation(), chainImplementation);
    //     assertEq(bridgehub.getChainProxyAdmin(), chainProxyAdmin);
    //     assertEq(address(bridgehub.getAllowList()), address(allowList));
    //     assertEq(bridgehub.getPriorityTxMaxGasLimit(), priorityTxMaxGasLimit);
    // }
}
