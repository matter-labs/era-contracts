// // SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {DiamondAlreadyFrozen, Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract FreezeChainTest is ChainTypeManagerTest {
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

    // ───────────── the Bridgehub's owner as a second caller ─────────────
    // The fixture's `governor` owns both the CTM and the Bridgehub. The tests below hand the CTM to
    // an owner of its own first, as the v35 bootstrap hands it to its executor, so `governor` is
    // the Bridgehub's owner only. See {protocol-docs/ecosystem-upgrade-coordination.md#freezing-a-chain}.

    /// @dev Moves the CTM to a fresh owner through its two-step transfer and returns that owner.
    function _handTheCTMToItsOwnOwner() internal returns (address ctmOwner) {
        ctmOwner = makeAddr("ctmOwner");
        vm.prank(governor);
        chainContractAddress.transferOwnership(ctmOwner);
        vm.prank(ctmOwner);
        chainContractAddress.acceptOwnership();
        assertEq(chainContractAddress.owner(), ctmOwner);
        assertEq(bridgehub.owner(), governor, "fixture: governor keeps the Bridgehub");
    }

    function _chainWithBridgehubLookup() internal returns (GettersFacet chain) {
        address newChainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(newChainAddress);
        chain = GettersFacet(newChainAddress);
        assertFalse(chain.isDiamondStorageFrozen());
    }

    function test_bridgehubOwnerFreezesAndUnfreezesAChainOfACTMItDoesNotOwn() public {
        GettersFacet chain = _chainWithBridgehubLookup();
        _handTheCTMToItsOwnOwner();

        vm.expectEmit(true, true, true, true, address(chain));
        emit IAdmin.Freeze();
        vm.prank(governor);
        chainContractAddress.freezeChain(chainId);
        assertTrue(chain.isDiamondStorageFrozen(), "the Bridgehub's owner froze the chain");

        vm.expectEmit(true, true, true, true, address(chain));
        emit IAdmin.Unfreeze();
        vm.prank(governor);
        chainContractAddress.unfreezeChain(chainId);
        assertFalse(chain.isDiamondStorageFrozen(), "and unfroze it");
    }

    function test_ctmOwnerStillFreezesAndUnfreezes() public {
        GettersFacet chain = _chainWithBridgehubLookup();
        address ctmOwner = _handTheCTMToItsOwnOwner();

        vm.prank(ctmOwner);
        chainContractAddress.freezeChain(chainId);
        assertTrue(chain.isDiamondStorageFrozen());

        vm.prank(ctmOwner);
        chainContractAddress.unfreezeChain(chainId);
        assertFalse(chain.isDiamondStorageFrozen());
    }

    /// @dev The CTM's admin manages non-critical settings (`onlyOwnerOrAdmin`); freezing is not one.
    function test_revertWhen_theCTMAdminFreezesOrUnfreezes() public {
        GettersFacet chain = _chainWithBridgehubLookup();
        address ctmOwner = _handTheCTMToItsOwnOwner();
        address ctmAdmin = makeAddr("ctmAdmin");
        vm.prank(ctmOwner);
        chainContractAddress.setPendingAdmin(ctmAdmin);
        vm.prank(ctmAdmin);
        chainContractAddress.acceptAdmin();
        assertEq(chainContractAddress.admin(), ctmAdmin);

        vm.prank(ctmAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, ctmAdmin));
        chainContractAddress.freezeChain(chainId);

        vm.prank(ctmOwner);
        chainContractAddress.freezeChain(chainId);
        vm.prank(ctmAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, ctmAdmin));
        chainContractAddress.unfreezeChain(chainId);
        assertTrue(chain.isDiamondStorageFrozen(), "the admin's unfreeze did not land");
    }

    /// @dev The second caller is whoever owns the Bridgehub NOW: a nominee is refused until it
    ///      accepts, and the previous owner is refused from then on.
    function test_theSecondCallerFollowsTheBridgehubsOwnership() public {
        GettersFacet chain = _chainWithBridgehubLookup();
        _handTheCTMToItsOwnOwner();
        address newBridgehubOwner = makeAddr("newBridgehubOwner");
        vm.prank(governor);
        bridgehub.transferOwnership(newBridgehubOwner);

        vm.prank(newBridgehubOwner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, newBridgehubOwner));
        chainContractAddress.freezeChain(chainId);

        vm.prank(newBridgehubOwner);
        bridgehub.acceptOwnership();

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governor));
        chainContractAddress.freezeChain(chainId);
        assertFalse(chain.isDiamondStorageFrozen(), "neither refused call froze the chain");

        vm.prank(newBridgehubOwner);
        chainContractAddress.freezeChain(chainId);
        assertTrue(chain.isDiamondStorageFrozen(), "the new owner freezes");
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governor));
        chainContractAddress.unfreezeChain(chainId);
        assertTrue(chain.isDiamondStorageFrozen(), "and the previous one cannot unfreeze");
    }

    /// @dev `admin` is the CTM proxy's admin, which the transparent proxy never forwards.
    function testFuzz_revertWhen_callerOwnsNeitherTheCTMNorTheBridgehub(address _caller) public {
        GettersFacet chain = _chainWithBridgehubLookup();
        address ctmOwner = _handTheCTMToItsOwnOwner();
        vm.assume(_caller != ctmOwner && _caller != governor && _caller != admin);

        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        chainContractAddress.freezeChain(chainId);
        assertFalse(chain.isDiamondStorageFrozen());

        vm.prank(ctmOwner);
        chainContractAddress.freezeChain(chainId);
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        chainContractAddress.unfreezeChain(chainId);
        assertTrue(chain.isDiamondStorageFrozen());
    }
}
