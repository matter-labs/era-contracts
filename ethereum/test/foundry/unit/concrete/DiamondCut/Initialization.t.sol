// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// solhint-disable max-line-length

import {DiamondCutTest} from "./_DiamondCut_Shared.t.sol";
import {RevertFallback} from "../../../../../cache/solpp-generated-contracts/dev-contracts/RevertFallback.sol";
import {ReturnSomething} from "../../../../../cache/solpp-generated-contracts/dev-contracts/ReturnSomething.sol";
import {DiamondCutTestContract} from "../../../../../cache/solpp-generated-contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {Diamond} from "../../../../../cache/solpp-generated-contracts/zksync/libraries/Diamond.sol";

// solhint-enable max-line-length

contract InitializationTest is DiamondCutTest {
    address private revertFallbackAddress;
    address private returnSomethingAddress;
    address private signerAddress; // EOA

    function setUp() public {
        signerAddress = makeAddr("signer");
        diamondCutTestContract = new DiamondCutTestContract();
        revertFallbackAddress = address(new RevertFallback());
        returnSomethingAddress = address(new ReturnSomething());
    }

    function test_RevertWhen_DelegateCallToFailedContract() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: revertFallbackAddress,
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("I"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_ReverWhen_DelegateCallToEOA() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: signerAddress,
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("lp"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_InitializingDiamondCutWithZeroAddressAndNonZeroData() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("0x11")
        });

        vm.expectRevert(abi.encodePacked("H"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_DelegateCallToAContractWithWrongReturn() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: returnSomethingAddress,
            initCalldata: bytes("")
        });

        vm.expectRevert(abi.encodePacked("lp1"));
        diamondCutTestContract.diamondCut(diamondCutData);
    }
}
