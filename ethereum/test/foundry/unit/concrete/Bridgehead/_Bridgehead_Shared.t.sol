// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {DiamondProxy} from "../../../../../cache/solpp-generated-contracts/common/DiamondProxy.sol";
import {BridgeheadDiamondInit} from "../../../../../cache/solpp-generated-contracts/bridgehead/bridgehead-deps/BridgeheadDiamondInit.sol";
import {IAllowList} from "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {Diamond} from "../../../../../cache/solpp-generated-contracts/common/libraries/Diamond.sol";

contract BridgeheadTest is Test {
    DiamondProxy internal bridgehead;
    BridgeheadDiamondInit internal bridgeheadDiamondInit;
    address internal constant GOVERNOR = address(0x101010101010101010101);
    address internal constant NON_GOVERNOR = address(0x202020202020202020202);

    constructor() {
        
        vm.chainId(31337);
        bridgeheadDiamondInit = new BridgeheadDiamondInit();

        bridgehead = new DiamondProxy(block.chainid, getDiamondCutData(address(bridgeheadDiamondInit)));
    }

    function getDiamondCutData(address diamondInit) internal returns (Diamond.DiamondCutData memory) {
        address governor = GOVERNOR;
        IAllowList allowList = IAllowList(GOVERNOR);

        bytes memory initCalldata = abi.encodeWithSelector(BridgeheadDiamondInit.initialize.selector, governor, allowList);

        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: diamondInit,
                initCalldata: initCalldata
            });
    }
}
