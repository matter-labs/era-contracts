// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";

contract DeployDiamondProxy is Script {
    function run() external {
        vm.startBroadcast();

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: address(0),
            initCalldata: ""
        });

        DiamondProxy proxy = new DiamondProxy(block.chainid, diamondCut);

        console.log("DiamondProxy deployed at:", address(proxy));

        vm.stopBroadcast();
    }
}
