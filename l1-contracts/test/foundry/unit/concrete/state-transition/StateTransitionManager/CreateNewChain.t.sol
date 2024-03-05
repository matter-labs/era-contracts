// // SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "solpp/state-transition/chain-deps/DiamondProxy.sol";

contract createNewChainTest is StateTransitionManagerTest {
    function test_RevertWhen_InitialDiamondCutHashMismatch() public {
        Diamond.DiamondCutData memory initialDiamondCutData = getDiamondCutData(sharedBridge);

        vm.expectRevert(bytes("StateTransition: initial cutHash mismatch"));

        createNewChain(initialDiamondCutData);
    }

    function test_RevertWhen_CalledNotByBridgehub() public {
        Diamond.DiamondCutData memory initialDiamondCutData = getDiamondCutData(diamondInit);

        vm.expectRevert(bytes("StateTransition: only bridgehub"));

        chainContractAddress.createNewChain(chainId, baseToken, sharedBridge, admin, abi.encode(initialDiamondCutData));
    }

    function test_SuccessfulCreationOfNewChain() public {
        createNewChain(getDiamondCutData(diamondInit));

        address admin = chainContractAddress.getChainAdmin(chainId);
        address newChainAddress = chainContractAddress.stateTransition(chainId);

        assertEq(newChainAdmin, admin);
        assertNotEq(newChainAddress, address(0));
    }
}
