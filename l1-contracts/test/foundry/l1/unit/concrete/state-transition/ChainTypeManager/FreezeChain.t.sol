// // SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

contract freezeChainTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    function test_FreezingChain() public {
        address newChainAddress = createNewChain(getDiamondCutData(diamondInit));
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehub.getZKChain.selector),
            abi.encode(newChainAddress)
        );
        GettersFacet gettersFacet = GettersFacet(newChainAddress);
        bool isChainFrozen = gettersFacet.isDiamondStorageFrozen();
        assertEq(isChainFrozen, false);
        vm.stopPrank();
        vm.startPrank(governor);
        chainContractAddress.freezeChain(block.chainid);
        // Repeated call should revert
        vm.expectRevert(bytes("q1")); // storage frozen
        chainContractAddress.freezeChain(block.chainid);
        // Call fails as storage is frozen
        vm.expectRevert(bytes("q1"));
        isChainFrozen = gettersFacet.isDiamondStorageFrozen();
    }

    function test_RevertWhen_UnfreezingChain() public {
        uint256 newChainid = 10;
        createNewChainWithId(getDiamondCutData(diamondInit), newChainid);

        address newChainAddress = chainContractAddress.getHyperchain(newChainid);
        GettersFacet gettersFacet = GettersFacet(newChainAddress);
        bool isChainFrozen = gettersFacet.isDiamondStorageFrozen();
        assertEq(isChainFrozen, false);

        chainContractAddress.freezeChain(newChainid);

        vm.expectRevert(bytes.concat("q1"));
        chainContractAddress.unfreezeChain(newChainid);
    }
}
