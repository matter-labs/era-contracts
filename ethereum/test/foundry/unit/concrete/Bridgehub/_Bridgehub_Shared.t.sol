// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {DiamondProxy} from "../../../../../cache/solpp-generated-contracts/common/DiamondProxy.sol";
import {BridgehubDiamondInit} from "../../../../../cache/solpp-generated-contracts/bridgehub/bridgehub-deps/BridgehubDiamondInit.sol";
import {IAllowList} from "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {Diamond} from "../../../../../cache/solpp-generated-contracts/common/libraries/Diamond.sol";

contract BridgehubTest is Test {
    DiamondProxy internal bridgehub;
    BridgehubDiamondInit internal bridgehubDiamondInit;
    address internal constant GOVERNOR = address(0x101010101010101010101);
    address internal constant NON_GOVERNOR = address(0x202020202020202020202);

    constructor() {
        vm.chainId(31337);
        bridgehubDiamondInit = new BridgehubDiamondInit();

        bridgehub = new DiamondProxy(block.chainid, getDiamondCutData(address(bridgehubDiamondInit)));
    }

    function getDiamondCutData(address diamondInit) internal returns (Diamond.DiamondCutData memory) {
        address governor = GOVERNOR;
        IAllowList allowList = IAllowList(GOVERNOR);

        bytes memory initCalldata = abi.encodeWithSelector(
            BridgehubDiamondInit.initialize.selector,
            governor,
            allowList
        );

        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: diamondInit,
                initCalldata: initCalldata
            });
    }
}
