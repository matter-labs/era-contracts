// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {InitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

contract DiamondInitTest is UtilsCallMockerTest {
    Diamond.FacetCut[] internal facetCuts;
    address internal testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    DummyBridgehub internal dummyBridgehub;
    InitializeData internal initializeData;

    function setUp() public virtual {
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new UtilsFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getUtilsFacetSelectors()
            })
        );
        dummyBridgehub = new DummyBridgehub();
        initializeData = Utils.makeInitializeData(testnetVerifier, address(dummyBridgehub));

        mockDiamondInitInteropCenterCallsWithAddress(address(dummyBridgehub), address(0), bytes32(0));
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
