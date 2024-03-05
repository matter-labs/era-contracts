// // SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "solpp/state-transition/chain-deps/DiamondProxy.sol";

contract createNewChainTest is StateTransitionManagerTest {
    function testRevertWhenInitialDiamondCutHashMismatch() public {
        address baseToken = address(0x3030303);
        address sharedBridge = address(0x4040404);
        address admin = bridgehub;
        uint256 chainId = block.chainid;
        Diamond.DiamondCutData memory initialDiamondCutData = getDiamondCutData(sharedBridge);

        vm.stopPrank();
        vm.startPrank(bridgehub);
        vm.expectRevert(bytes("StateTransition: initial cutHash mismatch"));

        chainContractAddress.createNewChain(chainId, baseToken, sharedBridge, admin, abi.encode(initialDiamondCutData));
    }

    function testRevertWhenCalledNotByBridgehub() public {
        address baseToken = address(0x3030303);
        address sharedBridge = address(0x4040404);
        address admin = bridgehub;
        uint256 chainId = block.chainid;
        Diamond.DiamondCutData memory initialDiamondCutData = getDiamondCutData(diamondInit);

        vm.expectRevert(bytes("StateTransition: only bridgehub"));

        chainContractAddress.createNewChain(chainId, baseToken, sharedBridge, admin, abi.encode(initialDiamondCutData));
    }

    function testSuccessfulCreationOfNewChain() public {
        address baseToken = address(0x3030303);
        address sharedBridge = address(0x4040404);
        address admin = bridgehub;
        uint256 chainId = block.chainid;

        vm.stopPrank();
        vm.startPrank(bridgehub);

        chainContractAddress.createNewChain(
            chainId,
            baseToken,
            sharedBridge,
            admin,
            abi.encode(getDiamondCutData(diamondInit))
        );

        address newChainAdmin = chainContractAddress.getChainAdmin(chainId);
        address newChainAddress = chainContractAddress.stateTransition(chainId);

        assertEq(newChainAdmin, admin);
        assertNotEq(newChainAddress, address(0));
    }
}
