// // SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";

contract freezeChainTest is ChainTypeManagerTest {
    // function test_FreezingChain() public {
    //     createNewChain(getDiamondCutData(diamondInit));
    //     address newChainAddress = chainContractAddress.getZKChain(chainId);
    //     GettersFacet gettersFacet = GettersFacet(newChainAddress);
    //     bool isChainFrozen = gettersFacet.isDiamondStorageFrozen();
    //     assertEq(isChainFrozen, false);
    //     vm.stopPrank();
    //     vm.startPrank(governor);
    //     chainContractAddress.freezeChain(block.chainid);
    //     // Repeated call should revert
    //     vm.expectRevert(bytes("q1")); // storage frozen
    //     chainContractAddress.freezeChain(block.chainid);
    //     // Call fails as storage is frozen
    //     vm.expectRevert(bytes("q1"));
    //     isChainFrozen = gettersFacet.isDiamondStorageFrozen();
    // }
}
