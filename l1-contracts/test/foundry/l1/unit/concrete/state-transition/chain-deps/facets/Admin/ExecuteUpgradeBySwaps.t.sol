// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {
    FacetSwapEmptySelectors,
    FacetSwapSameFacet,
    FacetSwapUnknownOldFacet,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondCutBuilder} from "contracts/state-transition/libraries/DiamondCutBuilder.sol";
import {ISelfDescribingFacet} from "contracts/state-transition/chain-interfaces/ISelfDescribingFacet.sol";

/// @dev The v(N) test facet: serves `foo` and `common`.
contract FooFacet is ISelfDescribingFacet {
    function foo() external pure returns (uint256) {
        return 1;
    }

    function common() external pure returns (uint256) {
        return 10;
    }

    function selectors() public pure virtual returns (bytes4[] memory result) {
        result = new bytes4[](2);
        result[0] = FooFacet.foo.selector;
        result[1] = FooFacet.common.selector;
    }
}

/// @dev The v(N+1) test facet: drops `foo`, keeps `common` (with new behavior), adds `bar`.
contract BarFacet is ISelfDescribingFacet {
    function bar() external pure returns (uint256) {
        return 2;
    }

    function common() external pure returns (uint256) {
        return 20;
    }

    function selectors() public pure virtual returns (bytes4[] memory result) {
        result = new bytes4[](2);
        result[0] = BarFacet.bar.selector;
        result[1] = BarFacet.common.selector;
    }
}

/// @dev A facet whose selectors are disjoint from Foo/Bar, for pure-addition tests.
contract BazFacet is ISelfDescribingFacet {
    function baz() external pure returns (uint256) {
        return 3;
    }

    function selectors() public pure virtual returns (bytes4[] memory result) {
        result = new bytes4[](1);
        result[0] = BazFacet.baz.selector;
    }
}

/// @dev A misbehaving self-describing facet that declares no selectors.
contract EmptySelectorsFacet is ISelfDescribingFacet {
    function selectors() public pure virtual returns (bytes4[] memory result) {
        result = new bytes4[](0);
    }
}

/// @dev A diamond-cut initializer that records its execution.
contract InitMock {
    event Initialized(uint256 value);

    function init(uint256 _value) external returns (bytes32) {
        emit Initialized(_value);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

contract ExecuteUpgradeBySwapsTest is AdminTest {
    event ExecuteUpgrade(Diamond.DiamondCutData diamondCut);
    event Initialized(uint256 value);

    FooFacet internal fooFacet;
    BarFacet internal barFacet;

    function setUp() public override {
        super.setUp();
        fooFacet = new FooFacet();
        barFacet = new BarFacet();

        // Install the v(N) facet with a classic cut, so swaps have something to diff against.
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(fooFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: fooFacet.selectors()
        });
        vm.prank(utilsFacet.util_getChainTypeManager());
        adminFacet.executeUpgrade(
            Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: address(0), initCalldata: hex""})
        );
    }

    function _swaps(
        address _oldFacet,
        address _newFacet,
        bool _isFreezable
    ) internal pure returns (DiamondCutBuilder.FacetSwap[] memory swaps) {
        swaps = new DiamondCutBuilder.FacetSwap[](1);
        swaps[0] = DiamondCutBuilder.FacetSwap({oldFacet: _oldFacet, newFacet: _newFacet, isFreezable: _isFreezable});
    }

    /*//////////////////////////////////////////////////////////////
                             authorization
    //////////////////////////////////////////////////////////////*/

    function test_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));
        vm.prank(nonChainTypeManager);
        adminFacet.executeUpgradeBySwaps(_swaps(address(fooFacet), address(barFacet), false), address(0), hex"");
    }

    /*//////////////////////////////////////////////////////////////
                             happy paths
    //////////////////////////////////////////////////////////////*/

    function test_successfulSwap_replacesRemovesAndAdds() public {
        vm.expectEmit(false, false, false, false, address(adminFacet));
        emit ExecuteUpgrade(
            Diamond.DiamondCutData({facetCuts: new Diamond.FacetCut[](0), initAddress: address(0), initCalldata: hex""})
        );

        vm.prank(utilsFacet.util_getChainTypeManager());
        adminFacet.executeUpgradeBySwaps(_swaps(address(fooFacet), address(barFacet), false), address(0), hex"");

        // Selector routing is the storage this upgrade changes; assert it through dispatch.
        // `bar` was added and `common` re-pointed to the new facet...
        assertEq(BarFacet(address(adminFacet)).bar(), 2);
        assertEq(BarFacet(address(adminFacet)).common(), 20);
        // ...and `foo` was removed: the diamond proxy has no facet for it anymore.
        vm.expectRevert();
        FooFacet(address(adminFacet)).foo();
    }

    function test_successfulSwap_pureAddition() public {
        // A pure addition installs a facet with disjoint selectors without touching any
        // existing one.
        BazFacet bazFacet = new BazFacet();

        vm.prank(utilsFacet.util_getChainTypeManager());
        adminFacet.executeUpgradeBySwaps(_swaps(address(0), address(bazFacet), false), address(0), hex"");

        assertEq(BazFacet(address(adminFacet)).baz(), 3);
        // The installed FooFacet keeps its routing.
        assertEq(FooFacet(address(adminFacet)).foo(), 1);
        assertEq(FooFacet(address(adminFacet)).common(), 10);
    }

    function test_successfulSwap_pureRemoval() public {
        vm.prank(utilsFacet.util_getChainTypeManager());
        adminFacet.executeUpgradeBySwaps(_swaps(address(fooFacet), address(0), false), address(0), hex"");

        vm.expectRevert();
        FooFacet(address(adminFacet)).foo();
        vm.expectRevert();
        FooFacet(address(adminFacet)).common();
    }

    function test_successfulSwap_runsInitDelegatecall() public {
        InitMock initMock = new InitMock();

        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit Initialized(99);

        vm.prank(utilsFacet.util_getChainTypeManager());
        adminFacet.executeUpgradeBySwaps(
            _swaps(address(fooFacet), address(barFacet), false),
            address(initMock),
            abi.encodeCall(InitMock.init, (99))
        );
    }

    function test_swapCarriesFreezability_freezableSelectorFrozen() public {
        // The swap carries the new facet's freezability into the cut: after freezing the
        // diamond, the freezable selector becomes inaccessible ("q1" is the DiamondProxy
        // frozen-facet marker). The fixture cannot unfreeze afterwards (its AdminFacet is
        // itself installed as freezable), so freezing is asserted one-way here and the
        // non-freezable direction is a separate test.
        vm.startPrank(utilsFacet.util_getChainTypeManager());
        adminFacet.executeUpgradeBySwaps(_swaps(address(fooFacet), address(barFacet), true), address(0), hex"");
        adminFacet.freezeDiamond();
        vm.stopPrank();

        vm.expectRevert(bytes("q1"));
        BarFacet(address(adminFacet)).bar();
    }

    function test_swapCarriesFreezability_nonFreezableSelectorSurvivesFreeze() public {
        vm.startPrank(utilsFacet.util_getChainTypeManager());
        adminFacet.executeUpgradeBySwaps(_swaps(address(fooFacet), address(barFacet), false), address(0), hex"");
        adminFacet.freezeDiamond();
        vm.stopPrank();

        assertEq(BarFacet(address(adminFacet)).bar(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                             unhappy paths
    //////////////////////////////////////////////////////////////*/

    function test_revertWhen_sameFacetSwap() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();

        vm.expectRevert(abi.encodeWithSelector(FacetSwapSameFacet.selector, address(fooFacet)));
        vm.prank(chainTypeManager);
        adminFacet.executeUpgradeBySwaps(_swaps(address(fooFacet), address(fooFacet), false), address(0), hex"");
    }

    function test_revertWhen_bothFacetsZero() public {
        address chainTypeManager = utilsFacet.util_getChainTypeManager();

        vm.expectRevert(abi.encodeWithSelector(FacetSwapSameFacet.selector, address(0)));
        vm.prank(chainTypeManager);
        adminFacet.executeUpgradeBySwaps(_swaps(address(0), address(0), false), address(0), hex"");
    }

    function test_revertWhen_oldFacetNotInstalled() public {
        address notInstalled = makeAddr("notInstalled");

        address chainTypeManager = utilsFacet.util_getChainTypeManager();

        vm.expectRevert(abi.encodeWithSelector(FacetSwapUnknownOldFacet.selector, notInstalled));
        vm.prank(chainTypeManager);
        adminFacet.executeUpgradeBySwaps(_swaps(notInstalled, address(barFacet), false), address(0), hex"");
    }

    function test_revertWhen_newFacetDeclaresNoSelectors() public {
        EmptySelectorsFacet emptyFacet = new EmptySelectorsFacet();

        address chainTypeManager = utilsFacet.util_getChainTypeManager();

        vm.expectRevert(abi.encodeWithSelector(FacetSwapEmptySelectors.selector, address(emptyFacet)));
        vm.prank(chainTypeManager);
        adminFacet.executeUpgradeBySwaps(_swaps(address(fooFacet), address(emptyFacet), false), address(0), hex"");
    }

    function test_revertWhen_addedSelectorCollidesWithInstalledFacet() public {
        // Adding BarFacet without swapping FooFacet out collides on `common`, which FooFacet
        // still serves; Diamond.diamondCut rejects the Add.
        FooFacet secondFoo = new FooFacet();

        address chainTypeManager = utilsFacet.util_getChainTypeManager();

        vm.expectRevert();
        vm.prank(chainTypeManager);
        adminFacet.executeUpgradeBySwaps(_swaps(address(0), address(secondFoo), false), address(0), hex"");
    }

    /*//////////////////////////////////////////////////////////////
                                edge cases
    //////////////////////////////////////////////////////////////*/

    function test_selectorMovesAcrossSwapsInOneUpgrade() public {
        // `common` moves from FooFacet (removed in swap 0, since swap 0's new facet is zero)
        // and is re-added by swap 1's BarFacet. This only works because the builder groups
        // all removals before all additions.
        DiamondCutBuilder.FacetSwap[] memory swaps = new DiamondCutBuilder.FacetSwap[](2);
        swaps[0] = DiamondCutBuilder.FacetSwap({oldFacet: address(fooFacet), newFacet: address(0), isFreezable: false});
        swaps[1] = DiamondCutBuilder.FacetSwap({oldFacet: address(0), newFacet: address(barFacet), isFreezable: false});

        vm.prank(utilsFacet.util_getChainTypeManager());
        adminFacet.executeUpgradeBySwaps(swaps, address(0), hex"");

        assertEq(BarFacet(address(adminFacet)).bar(), 2);
        assertEq(BarFacet(address(adminFacet)).common(), 20);
        vm.expectRevert();
        FooFacet(address(adminFacet)).foo();
    }
}
