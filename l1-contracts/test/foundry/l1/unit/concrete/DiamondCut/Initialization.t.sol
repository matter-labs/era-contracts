// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DiamondCutTest} from "./_DiamondCut_Shared.t.sol";
import {RevertFallback} from "contracts/dev-contracts/RevertFallback.sol";
import {ReturnSomething} from "contracts/dev-contracts/ReturnSomething.sol";
import {DiamondCutTestContract} from "contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DelegateCallFailed, NonEmptyCalldata} from "contracts/common/L1ContractErrors.sol";
import {Utils} from "../Utils/Utils.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";

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
        bytes memory emptyBytes;
        vm.expectRevert(abi.encodeWithSelector(DelegateCallFailed.selector, emptyBytes));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_DelegateCallWithWrongInitializeData() public {
        DiamondInit diamondInit = new DiamondInit();
        bytes memory diamondInitData = abi.encodeWithSelector(
            diamondInit.initialize.selector,
            Utils.makeInitializeData(address(0))
        );
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(diamondInit),
            initCalldata: diamondInitData
        });

        vm.expectRevert();
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_DelegateCallToEOA() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: signerAddress,
            initCalldata: bytes("")
        });
        bytes memory emptyBytes;
        vm.expectRevert(abi.encodeWithSelector(DelegateCallFailed.selector, emptyBytes));
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_InitializingDiamondCutWithZeroAddressAndNonZeroData() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: bytes("0x11")
        });

        vm.expectRevert(NonEmptyCalldata.selector);
        diamondCutTestContract.diamondCut(diamondCutData);
    }

    function test_RevertWhen_DelegateCallToAContractWithWrongReturn() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCutData = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: returnSomethingAddress,
            initCalldata: bytes("")
        });
        bytes memory returnData = hex"0000000000000000000000000000000000000000000000000000000000000000";
        vm.expectRevert(abi.encodeWithSelector(DelegateCallFailed.selector, returnData));
        diamondCutTestContract.diamondCut(diamondCutData);
    }
}
