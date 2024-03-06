// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Vm} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {RegistryTest} from "./_Registry_Shared.t.sol";

import {IStateTransitionManager} from "solpp/state-transition/IStateTransitionManager.sol";

contract NewChainTest is RegistryTest {
    uint256 internal chainId;
    address internal governorAddress;

    // function setUp() public {
    //     chainId = 838383838383;
    //     stateTransitionAddress = makeAddr("chainStateTransitionAddress");
    //     governorAddress = makeAddr("governorAddress");
    //     allowList = new AllowList(governorAddress);

    //     vm.prank(GOVERNOR);
    //     bridgehub.addStateTransition(stateTransitionAddress);
    // }

    // function getStateTransitionAddress() internal returns (address chainContractAddress) {
    //     // vm.mockCall(
    //     //     bridgehub.getChainImplementation(),
    //     //     abi.encodeWithSelector(IBridgehubChain.initialize.selector),
    //     //     ""
    //     // );

    //     uint256 snapshot = vm.snapshot();
    //     vm.startPrank(address(bridgehub));

    //     // bytes memory data = abi.encodeWithSelector(
    //     //     IBridgehubChain.initialize.selector,
    //     //     chainId,
    //     //     stateTransitionAddress,
    //     //     governorAddress,
    //     //     allowList,
    //     //     bridgehub.getPriorityTxMaxGasLimit()
    //     // );
    //     // TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
    //     //     bridgehub.getChainImplementation(),
    //     //     bridgehub.getChainProxyAdmin(),
    //     //     data
    //     // );
    //     // chainContractAddress = address(transparentUpgradeableProxy);

    //     vm.stopPrank();
    //     vm.revertTo(snapshot);
    // }

    // function test_RevertWhen_NonGovernor() public {
    //     vm.startPrank(NON_GOVERNOR);
    //     vm.expectRevert(bytes.concat("12g"));
    //     bridgehub.createNewChain(chainId, stateTransitionAddress, governorAddress, allowList, getDiamondCutData());
    // }

    // function test_RevertWhen_StateTransitionIsNotInStorage() public {
    //     address nonExistentStateTransitionAddress = address(0x3030303);

    //     vm.startPrank(GOVERNOR);
    //     vm.expectRevert(bytes.concat("r19"));
    //     bridgehub.createNewChain(
    //         chainId,
    //         nonExistentStateTransitionAddress,
    //         governorAddress,
    //         allowList,
    //         getDiamondCutData()
    //     );
    // }

    // function test_RevertWhen_ChainIdIsAlreadyInUse() public {
    //     // vm.mockCall(
    //     //     bridgehub.getChainImplementation(),
    //     //     abi.encodeWithSelector(IBridgehubChain.initialize.selector),
    //     //     ""
    //     // );
    //     vm.mockCall(stateTransitionAddress, abi.encodeWithSelector(IStateTransitionManager.newChain.selector), "");

    //     vm.startPrank(GOVERNOR);
    //     bridgehub.createNewChain(chainId, stateTransitionAddress, governorAddress, allowList, getDiamondCutData());

    //     vm.expectRevert(bytes.concat("r20"));
    //     bridgehub.createNewChain(chainId, stateTransitionAddress, governorAddress, allowList, getDiamondCutData());
    // }

    // function test_NewChainSuccessfullyWithNonZeroChainId() public {
    //     // === Shared variables ===
    //     address chainContractAddress = getStateTransitionAddress();

    //     // === Mocking ===
    //     // vm.mockCall(
    //     //     bridgehub.getChainImplementation(),
    //     //     abi.encodeWithSelector(IBridgehubChain.initialize.selector),
    //     //     ""
    //     // );
    //     vm.mockCall(stateTransitionAddress, abi.encodeWithSelector(IStateTransitionManager.newChain.selector), "");

    //     // === Internal call checks ===
    //     // vm.expectCall(
    //     //     bridgehub.getChainImplementation(),
    //     //     abi.encodeWithSelector(
    //     //         IBridgehubChain.initialize.selector,
    //     //         chainId,
    //     //         stateTransitionAddress,
    //     //         governorAddress,
    //     //         allowList,
    //     //         bridgehub.getPriorityTxMaxGasLimit()
    //     //     ),
    //     //     1
    //     // );
    //     vm.expectCall(
    //         stateTransitionAddress,
    //         abi.encodeWithSelector(
    //             IStateTransitionManager.newChain.selector,
    //             chainId,
    //             chainContractAddress,
    //             governorAddress,
    //             getDiamondCutData()
    //         ),
    //         1
    //     );

    //     // === Function call ===
    //     vm.recordLogs();
    //     vm.startPrank(GOVERNOR);

    //     uint256 resChainId = bridgehub.createNewChain(
    //         chainId,
    //         stateTransitionAddress,
    //         governorAddress,
    //         allowList,
    //         getDiamondCutData()
    //     );

    //     vm.stopPrank();
    //     Vm.Log[] memory entries = vm.getRecordedLogs();

    //     // === Emitted event checks ===
    //     assertEq(entries[2].topics[0], IRegistry.NewChain.selector, "NewChain event not emitted");
    //     assertEq(entries[2].topics.length, 4, "NewChain event should have 4 topics");

    //     uint16 eventChainId = abi.decode(abi.encode(entries[2].topics[1]), (uint16));
    //     address eventChainContract = abi.decode(abi.encode(entries[2].topics[2]), (address));
    //     address eventChainGovernnance = abi.decode(abi.encode(entries[2].topics[3]), (address));
    //     address eventStateTransition = abi.decode(entries[2].data, (address));

    //     assertEq(eventChainId, uint16(chainId), "NewChain.chainId is wrong");
    //     assertEq(eventChainContract, chainContractAddress, "NewChain.chainContract is wrong");
    //     assertEq(eventChainGovernnance, GOVERNOR, "NewChain.chainGovernance is wrong");
    //     assertEq(eventStateTransition, stateTransitionAddress, "NewChain.stateTransition is wrong");

    //     // === Storage checks ===
    //     assertEq(bridgehub.getStateTransition(chainId), stateTransitionAddress, "saved chainStateTransition is wrong");
    //     assertEq(bridgehub.getTotalChains(), 1, "saved totalChains is wrong");
    //     assertEq(bridgehub.getStateTransition(chainId), chainContractAddress, "saved chainContract address is wrong");
    //     assertEq(resChainId, chainId, "returned chainId is wrong");
    // }

    // function test_NewChainSuccessfullyWithZeroChainId() public {
    //     // === Shared variables ===
    //     address chainContractAddress = getStateTransitionAddress();
    //     uint256 inputChainId = 0;
    //     chainId = uint16(
    //         uint256(
    //             keccak256(
    //                 abi.encodePacked(
    //                     "CHAIN_ID",
    //                     block.chainid,
    //                     address(bridgehub),
    //                     stateTransitionAddress,
    //                     block.timestamp,
    //                     GOVERNOR
    //                 )
    //             )
    //         )
    //     );

    //     // === Mocking ===
    //     // vm.mockCall(
    //     //     bridgehub.getChainImplementation(),
    //     //     abi.encodeWithSelector(IBridgehubChain.initialize.selector),
    //     //     ""
    //     // );
    //     vm.mockCall(stateTransitionAddress, abi.encodeWithSelector(IStateTransitionManager.newChain.selector), "");

    //     // === Internal call checks ===
    //     // vm.expectCall(
    //     //     bridgehub.getChainImplementation(),
    //     //     abi.encodeWithSelector(
    //     //         IBridgehubChain.initialize.selector,
    //     //         chainId,
    //     //         stateTransitionAddress,
    //     //         governorAddress,
    //     //         allowList,
    //     //         bridgehub.getPriorityTxMaxGasLimit()
    //     //     ),
    //     //     1
    //     // );
    //     vm.expectCall(
    //         stateTransitionAddress,
    //         abi.encodeWithSelector(
    //             IStateTransitionManager.newChain.selector,
    //             chainId,
    //             chainContractAddress,
    //             governorAddress,
    //             getDiamondCutData()
    //         ),
    //         1
    //     );

    //     // === Function call ===
    //     vm.recordLogs();
    //     vm.startPrank(GOVERNOR);

    //     uint256 resChainId = bridgehub.createNewChain(
    //         inputChainId,
    //         stateTransitionAddress,
    //         governorAddress,
    //         allowList,
    //         getDiamondCutData()
    //     );

    //     vm.stopPrank();
    //     Vm.Log[] memory entries = vm.getRecordedLogs();

    //     // === Emitted event checks ===
    //     assertEq(entries[2].topics[0], IRegistry.NewChain.selector, "NewChain event not emitted");
    //     assertEq(entries[2].topics.length, 4, "NewChain event should have 4 topics");

    //     uint16 eventChainId = abi.decode(abi.encode(entries[2].topics[1]), (uint16));
    //     address eventChainContract = abi.decode(abi.encode(entries[2].topics[2]), (address));
    //     address eventChainGovernnance = abi.decode(abi.encode(entries[2].topics[3]), (address));
    //     address eventStateTransition = abi.decode(entries[2].data, (address));

    //     assertEq(eventChainId, uint16(chainId), "NewChain.chainId is wrong");
    //     assertEq(eventChainContract, chainContractAddress, "NewChain.chainContract is wrong");
    //     assertEq(eventChainGovernnance, GOVERNOR, "NewChain.chainGovernance is wrong");
    //     assertEq(eventStateTransition, stateTransitionAddress, "NewChain.stateTransition is wrong");

    //     // === Storage checks ===
    //     assertEq(bridgehub.getStateTransition(chainId), stateTransitionAddress, "saved chainStateTransition is wrong");
    //     assertEq(bridgehub.getTotalChains(), 1, "saved totalChains is wrong");
    //     assertEq(bridgehub.getStateTransition(chainId), chainContractAddress, "saved chainContract address is wrong");
    //     assertEq(resChainId, chainId, "returned chainId is wrong");
    // }
}
