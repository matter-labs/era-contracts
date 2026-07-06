// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondCutBuilder} from "contracts/state-transition/libraries/DiamondCutBuilder.sol";

contract DiamondCutBuilderTest is Test {
    address internal oldFacet = makeAddr("oldFacet");
    address internal newFacet = makeAddr("newFacet");

    function _sel(uint32 _id) internal pure returns (bytes4) {
        return bytes4(uint32(_id));
    }

    function _selectors(uint32[] memory _ids) internal pure returns (bytes4[] memory result) {
        result = new bytes4[](_ids.length);
        for (uint256 i = 0; i < _ids.length; ++i) {
            result[i] = bytes4(_ids[i]);
        }
    }

    function _singleSwap(
        address _oldFacet,
        address _newFacet,
        bool _isFreezable
    ) internal pure returns (DiamondCutBuilder.FacetSwap[] memory swaps) {
        swaps = new DiamondCutBuilder.FacetSwap[](1);
        swaps[0] = DiamondCutBuilder.FacetSwap({oldFacet: _oldFacet, newFacet: _newFacet, isFreezable: _isFreezable});
    }

    /*//////////////////////////////////////////////////////////////
                            splitSelectors
    //////////////////////////////////////////////////////////////*/

    function test_splitSelectors_identicalSets() public pure {
        uint32[] memory ids = new uint32[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        bytes4[] memory old = _selectors(ids);
        bytes4[] memory updated = _selectors(ids);

        (bytes4[] memory removed, bytes4[] memory replaced, bytes4[] memory added) = DiamondCutBuilder.splitSelectors(
            old,
            updated
        );

        assertEq(removed.length, 0, "nothing should be removed");
        assertEq(added.length, 0, "nothing should be added");
        assertEq(replaced.length, 3, "all selectors should be replaced");
        assertEq(replaced[0], bytes4(uint32(1)));
        assertEq(replaced[1], bytes4(uint32(2)));
        assertEq(replaced[2], bytes4(uint32(3)));
    }

    function test_splitSelectors_disjointSets() public pure {
        uint32[] memory oldIds = new uint32[](2);
        oldIds[0] = 1;
        oldIds[1] = 2;
        uint32[] memory newIds = new uint32[](2);
        newIds[0] = 3;
        newIds[1] = 4;

        (bytes4[] memory removed, bytes4[] memory replaced, bytes4[] memory added) = DiamondCutBuilder.splitSelectors(
            _selectors(oldIds),
            _selectors(newIds)
        );

        assertEq(replaced.length, 0, "nothing should be replaced");
        assertEq(removed.length, 2, "all old selectors should be removed");
        assertEq(removed[0], bytes4(uint32(1)));
        assertEq(removed[1], bytes4(uint32(2)));
        assertEq(added.length, 2, "all new selectors should be added");
        assertEq(added[0], bytes4(uint32(3)));
        assertEq(added[1], bytes4(uint32(4)));
    }

    function test_splitSelectors_partialOverlap() public pure {
        uint32[] memory oldIds = new uint32[](3);
        oldIds[0] = 1;
        oldIds[1] = 2;
        oldIds[2] = 3;
        uint32[] memory newIds = new uint32[](3);
        newIds[0] = 2;
        newIds[1] = 3;
        newIds[2] = 4;

        (bytes4[] memory removed, bytes4[] memory replaced, bytes4[] memory added) = DiamondCutBuilder.splitSelectors(
            _selectors(oldIds),
            _selectors(newIds)
        );

        assertEq(removed.length, 1);
        assertEq(removed[0], bytes4(uint32(1)));
        assertEq(replaced.length, 2);
        assertEq(replaced[0], bytes4(uint32(2)));
        assertEq(replaced[1], bytes4(uint32(3)));
        assertEq(added.length, 1);
        assertEq(added[0], bytes4(uint32(4)));
    }

    function test_splitSelectors_emptyOld() public pure {
        uint32[] memory newIds = new uint32[](2);
        newIds[0] = 1;
        newIds[1] = 2;

        (bytes4[] memory removed, bytes4[] memory replaced, bytes4[] memory added) = DiamondCutBuilder.splitSelectors(
            new bytes4[](0),
            _selectors(newIds)
        );

        assertEq(removed.length, 0);
        assertEq(replaced.length, 0);
        assertEq(added.length, 2);
    }

    function test_splitSelectors_emptyNew() public pure {
        uint32[] memory oldIds = new uint32[](2);
        oldIds[0] = 1;
        oldIds[1] = 2;

        (bytes4[] memory removed, bytes4[] memory replaced, bytes4[] memory added) = DiamondCutBuilder.splitSelectors(
            _selectors(oldIds),
            new bytes4[](0)
        );

        assertEq(removed.length, 2);
        assertEq(replaced.length, 0);
        assertEq(added.length, 0);
    }

    function test_splitSelectors_bothEmpty() public pure {
        (bytes4[] memory removed, bytes4[] memory replaced, bytes4[] memory added) = DiamondCutBuilder.splitSelectors(
            new bytes4[](0),
            new bytes4[](0)
        );

        assertEq(removed.length, 0);
        assertEq(replaced.length, 0);
        assertEq(added.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              buildCuts
    //////////////////////////////////////////////////////////////*/

    function test_buildCuts_replaceOnly() public {
        uint32[] memory ids = new uint32[](2);
        ids[0] = 1;
        ids[1] = 2;
        bytes4[][] memory oldSelectors = new bytes4[][](1);
        bytes4[][] memory newSelectors = new bytes4[][](1);
        oldSelectors[0] = _selectors(ids);
        newSelectors[0] = _selectors(ids);

        Diamond.FacetCut[] memory cuts = DiamondCutBuilder.buildCuts(
            _singleSwap(oldFacet, newFacet, true),
            oldSelectors,
            newSelectors
        );

        assertEq(cuts.length, 1, "identical selector sets should produce a single Replace cut");
        assertEq(uint256(cuts[0].action), uint256(Diamond.Action.Replace));
        assertEq(cuts[0].facet, newFacet);
        assertTrue(cuts[0].isFreezable);
        assertEq(cuts[0].selectors.length, 2);
    }

    function test_buildCuts_pureAddition() public {
        uint32[] memory ids = new uint32[](2);
        ids[0] = 1;
        ids[1] = 2;
        bytes4[][] memory oldSelectors = new bytes4[][](1);
        bytes4[][] memory newSelectors = new bytes4[][](1);
        oldSelectors[0] = new bytes4[](0);
        newSelectors[0] = _selectors(ids);

        Diamond.FacetCut[] memory cuts = DiamondCutBuilder.buildCuts(
            _singleSwap(address(0), newFacet, false),
            oldSelectors,
            newSelectors
        );

        assertEq(cuts.length, 1, "a pure addition should produce a single Add cut");
        assertEq(uint256(cuts[0].action), uint256(Diamond.Action.Add));
        assertEq(cuts[0].facet, newFacet);
        assertFalse(cuts[0].isFreezable);
        assertEq(cuts[0].selectors.length, 2);
    }

    function test_buildCuts_pureRemoval() public {
        uint32[] memory ids = new uint32[](2);
        ids[0] = 1;
        ids[1] = 2;
        bytes4[][] memory oldSelectors = new bytes4[][](1);
        bytes4[][] memory newSelectors = new bytes4[][](1);
        oldSelectors[0] = _selectors(ids);
        newSelectors[0] = new bytes4[](0);

        Diamond.FacetCut[] memory cuts = DiamondCutBuilder.buildCuts(
            _singleSwap(oldFacet, address(0), false),
            oldSelectors,
            newSelectors
        );

        assertEq(cuts.length, 1, "a pure removal should produce a single Remove cut");
        assertEq(uint256(cuts[0].action), uint256(Diamond.Action.Remove));
        // Diamond.sol requires the zero facet address on Remove cuts.
        assertEq(cuts[0].facet, address(0));
        assertEq(cuts[0].selectors.length, 2);
    }

    function test_buildCuts_mixedDiff() public {
        uint32[] memory oldIds = new uint32[](2);
        oldIds[0] = 1;
        oldIds[1] = 2;
        uint32[] memory newIds = new uint32[](2);
        newIds[0] = 2;
        newIds[1] = 3;
        bytes4[][] memory oldSelectors = new bytes4[][](1);
        bytes4[][] memory newSelectors = new bytes4[][](1);
        oldSelectors[0] = _selectors(oldIds);
        newSelectors[0] = _selectors(newIds);

        Diamond.FacetCut[] memory cuts = DiamondCutBuilder.buildCuts(
            _singleSwap(oldFacet, newFacet, true),
            oldSelectors,
            newSelectors
        );

        assertEq(cuts.length, 3);
        // Cuts are grouped Remove -> Replace -> Add.
        assertEq(uint256(cuts[0].action), uint256(Diamond.Action.Remove));
        assertEq(cuts[0].selectors[0], _sel(1));
        assertEq(uint256(cuts[1].action), uint256(Diamond.Action.Replace));
        assertEq(cuts[1].facet, newFacet);
        assertEq(cuts[1].selectors[0], _sel(2));
        assertEq(uint256(cuts[2].action), uint256(Diamond.Action.Add));
        assertEq(cuts[2].facet, newFacet);
        assertEq(cuts[2].selectors[0], _sel(3));
    }

    function test_buildCuts_multiSwapGroupsRemovalsFirst() public {
        // Selector 1 moves from facetA (swap 0, removed) to facetD (swap 1, added). The Remove
        // cut must precede the Add cut regardless of swap order, otherwise Diamond.diamondCut
        // reverts with FacetExists.
        address facetA = makeAddr("facetA");
        address facetB = makeAddr("facetB");
        address facetC = makeAddr("facetC");
        address facetD = makeAddr("facetD");

        uint32[] memory aIds = new uint32[](2);
        aIds[0] = 1;
        aIds[1] = 2;
        uint32[] memory bIds = new uint32[](1);
        bIds[0] = 2;
        uint32[] memory cIds = new uint32[](1);
        cIds[0] = 3;
        uint32[] memory dIds = new uint32[](2);
        dIds[0] = 3;
        dIds[1] = 1;

        DiamondCutBuilder.FacetSwap[] memory swaps = new DiamondCutBuilder.FacetSwap[](2);
        swaps[0] = DiamondCutBuilder.FacetSwap({oldFacet: facetA, newFacet: facetB, isFreezable: false});
        swaps[1] = DiamondCutBuilder.FacetSwap({oldFacet: facetC, newFacet: facetD, isFreezable: true});
        bytes4[][] memory oldSelectors = new bytes4[][](2);
        bytes4[][] memory newSelectors = new bytes4[][](2);
        oldSelectors[0] = _selectors(aIds);
        newSelectors[0] = _selectors(bIds);
        oldSelectors[1] = _selectors(cIds);
        newSelectors[1] = _selectors(dIds);

        Diamond.FacetCut[] memory cuts = DiamondCutBuilder.buildCuts(swaps, oldSelectors, newSelectors);

        // swap 0: remove 1, replace 2; swap 1: replace 3, add 1.
        assertEq(cuts.length, 4);
        assertEq(uint256(cuts[0].action), uint256(Diamond.Action.Remove));
        assertEq(cuts[0].selectors[0], _sel(1));
        assertEq(uint256(cuts[1].action), uint256(Diamond.Action.Replace));
        assertEq(cuts[1].facet, facetB);
        assertEq(uint256(cuts[2].action), uint256(Diamond.Action.Replace));
        assertEq(cuts[2].facet, facetD);
        assertEq(uint256(cuts[3].action), uint256(Diamond.Action.Add));
        assertEq(cuts[3].facet, facetD);
        assertEq(cuts[3].selectors[0], _sel(1));
    }

    function test_buildCuts_emptySwapListProducesNoCuts() public pure {
        Diamond.FacetCut[] memory cuts = DiamondCutBuilder.buildCuts(
            new DiamondCutBuilder.FacetSwap[](0),
            new bytes4[][](0),
            new bytes4[][](0)
        );

        assertEq(cuts.length, 0);
    }

    function test_buildCuts_emptyDiffContributesNoCuts() public {
        bytes4[][] memory oldSelectors = new bytes4[][](1);
        bytes4[][] memory newSelectors = new bytes4[][](1);
        oldSelectors[0] = new bytes4[](0);
        newSelectors[0] = new bytes4[](0);

        Diamond.FacetCut[] memory cuts = DiamondCutBuilder.buildCuts(
            _singleSwap(oldFacet, newFacet, false),
            oldSelectors,
            newSelectors
        );

        assertEq(cuts.length, 0, "an empty diff must not produce empty cuts that Diamond.diamondCut rejects");
    }
}
