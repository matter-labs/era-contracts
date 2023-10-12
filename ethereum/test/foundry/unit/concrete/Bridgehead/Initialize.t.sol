// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgeheadTest} from "./_Bridgehead_Shared.t.sol";
import {IAllowList} from "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {DiamondProxy} from "../../../../../cache/solpp-generated-contracts/common/DiamondProxy.sol";
import {BridgeheadDiamondInit} from "../../../../../cache/solpp-generated-contracts/bridgehead/bridgehead-deps/BridgeheadDiamondInit.sol";

contract InitializeTest is BridgeheadTest {
    address internal governor;
    address internal chainImplementation;
    address internal chainProxyAdmin;
    IAllowList internal allowList;
    uint256 internal priorityTxMaxGasLimit;

    function setUp() public {
        bridgeheadDiamondInit = new BridgeheadDiamondInit();

        governor = GOVERNOR;
        chainImplementation = makeAddr("chainImplementation");
        chainProxyAdmin = makeAddr("chainProxyAdmin");
        allowList = IAllowList(makeAddr("owner"));
        priorityTxMaxGasLimit = 1090193;
    }

    // function test_RevertWhen_AlreadyInitialized() public {
    //     bridgehead.initialize(governor, chainImplementation, chainProxyAdmin, allowList, priorityTxMaxGasLimit);

    //     vm.expectRevert(bytes.concat("bridgehead1"));
    //     bridgehead.initialize(governor, chainImplementation, chainProxyAdmin, allowList, priorityTxMaxGasLimit);
    // }

    // function test_InitializeSuccessfully() public {
    //     bridgehead.initialize(governor, chainImplementation, chainProxyAdmin, allowList, priorityTxMaxGasLimit);

    //     assertEq(bridgehead.getGovernor(), governor);
    //     assertEq(bridgehead.getChainImplementation(), chainImplementation);
    //     assertEq(bridgehead.getChainProxyAdmin(), chainProxyAdmin);
    //     assertEq(address(bridgehead.getAllowList()), address(allowList));
    //     assertEq(bridgehead.getPriorityTxMaxGasLimit(), priorityTxMaxGasLimit);
    // }
}
