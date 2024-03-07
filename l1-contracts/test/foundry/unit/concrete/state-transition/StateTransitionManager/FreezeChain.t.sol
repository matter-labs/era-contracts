// // SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "solpp/state-transition/chain-deps/DiamondProxy.sol";
import {GettersFacet} from "solpp/state-transition/chain-deps/facets/Getters.sol";

contract freezeChainTest is StateTransitionManagerTest {
    function test_FreezingChain() public {
        createNewChain(getDiamondCutData(diamondInit));

        address newChainAddress = chainContractAddress.stateTransition(chainId);
        GettersFacet gettersFacet = GettersFacet(newChainAddress);
        bool isChainFrozen = gettersFacet.isDiamondStorageFrozen();
        assertEq(isChainFrozen, false);

        vm.stopPrank();
        vm.startPrank(governor);

        chainContractAddress.freezeChain(block.chainid);

        // Repeated call should revert
        vm.expectRevert(bytes.concat("q1")); // storage frozen
        chainContractAddress.freezeChain(block.chainid);

        // Call fails as storage is frozen
        vm.expectRevert(bytes.concat("q1"));
        isChainFrozen = gettersFacet.isDiamondStorageFrozen();
    }
}
