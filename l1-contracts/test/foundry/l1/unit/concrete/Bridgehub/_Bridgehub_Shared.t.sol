// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IDiamondInit} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

contract BridgehubTest is Test {
    DiamondProxy internal bridgehub;
    IDiamondInit internal bridgehubDiamondInit;
    address internal GOVERNOR;
    address internal NON_GOVERNOR;

    constructor() {
        GOVERNOR = makeAddr("GOVERNOR");
        NON_GOVERNOR = makeAddr("NON_GOVERNOR");

        vm.chainId(31337);
        bridgehubDiamondInit = new DiamondInit(false);

        bridgehub = new DiamondProxy(block.chainid, getDiamondCutData(address(bridgehubDiamondInit)));
    }

    function getDiamondCutData(address diamondInit) internal view returns (Diamond.DiamondCutData memory) {
        address governor = GOVERNOR;
        bytes memory initCalldata = abi.encodeWithSelector(IDiamondInit.initialize.selector, governor);

        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: diamondInit,
                initCalldata: initCalldata
            });
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
