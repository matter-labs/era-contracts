// // SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

contract freezeChainTest is StateTransitionManagerTest {
    function test_FreezingChain() public {
        createNewChain(getDiamondCutData(diamondInit));

        address newChainAddress = chainContractAddress.getHyperchain(chainId);
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

    function test_RevertWhen_UnfreezingChain() public {
        uint256 newChainid = 10;
        createNewChainWithId(getDiamondCutData(diamondInit), newChainid);

        address newChainAddress = chainContractAddress.getHyperchain(newChainid);
        GettersFacet gettersFacet = GettersFacet(newChainAddress);
        bool isChainFrozen = gettersFacet.isDiamondStorageFrozen();
        assertEq(isChainFrozen, false);

        vm.stopPrank();
        vm.startPrank(governor);

        chainContractAddress.freezeChain(newChainid);

        vm.expectRevert(bytes.concat("q1"));
        chainContractAddress.unfreezeChain(newChainid);
    }
}
