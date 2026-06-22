// // SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {DiamondAlreadyFrozen} from "contracts/common/L1ContractErrors.sol";

contract freezeChainTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    function test_FreezingChain() public {
        address newChainAddress = createNewChain(getDiamondCutData(diamondInit));

        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector),
            abi.encode(newChainAddress)
        );

        GettersFacet gettersFacet = GettersFacet(newChainAddress);
        bool isChainFrozen = gettersFacet.isDiamondStorageFrozen();

        assertEq(isChainFrozen, false);

        vm.startPrank(governor);

        chainContractAddress.freezeChain(block.chainid);

        isChainFrozen = gettersFacet.isDiamondStorageFrozen();
        assertTrue(isChainFrozen);

        // Repeated call should revert
        vm.expectRevert(DiamondAlreadyFrozen.selector); // storage frozen
        chainContractAddress.freezeChain(block.chainid);

        vm.stopPrank();
    }

    function test_ChainTypeManagerCan_UnfreezeChain() public {
        address newChainAddress = createNewChain(getDiamondCutData(diamondInit));

        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector),
            abi.encode(newChainAddress)
        );

        GettersFacet gettersFacet = GettersFacet(newChainAddress);
        bool isChainFrozen = gettersFacet.isDiamondStorageFrozen();

        assertEq(isChainFrozen, false);

        vm.startPrank(governor);
        chainContractAddress.freezeChain(chainId);

        // Check to see if the chain has been frozen or not
        isChainFrozen = gettersFacet.isDiamondStorageFrozen();
        assertEq(isChainFrozen, true);

        // The governor (owner of ChainTypeManager) should be able to unfreeze the chain
        chainContractAddress.unfreezeChain(chainId);

        vm.stopPrank();

        isChainFrozen = gettersFacet.isDiamondStorageFrozen();
        assertEq(isChainFrozen, false);
    }
}
