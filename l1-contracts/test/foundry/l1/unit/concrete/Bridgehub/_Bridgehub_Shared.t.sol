// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {MigrationTestBase} from "test/foundry/l1/integration/unit-migration/_SharedMigrationBase.t.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IDiamondInit} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

contract BridgehubTest is MigrationTestBase {
    DiamondProxy internal bridgehubDiamond;
    IDiamondInit internal bridgehubDiamondInit;
    address internal GOVERNOR;
    address internal NON_GOVERNOR;

    function setUp() public virtual override {
        super.setUp();

        GOVERNOR = addresses.bridgehub.owner();
        NON_GOVERNOR = makeAddr("NON_GOVERNOR");

        // Create a fresh diamond for Initialize tests that need it
        bridgehubDiamondInit = new DiamondInit(false);
        bridgehubDiamond = new DiamondProxy(block.chainid, getDiamondCutData(address(bridgehubDiamondInit)));
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
    function test() internal virtual override {}
}
