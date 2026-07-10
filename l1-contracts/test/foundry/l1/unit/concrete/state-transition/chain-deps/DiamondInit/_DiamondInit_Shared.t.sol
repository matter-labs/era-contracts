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

contract DiamondInitTest is UtilsCallMockerTest {
    Diamond.FacetCut[] internal facetCuts;
    address internal testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    DummyBridgehub internal dummyBridgehub;

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

        // DiamondInit derives everything but (chainId, admin) from the CTM — msg.sender during
        // the proxy construction — so the fixtures prank as Utils.TEST_CHAIN_TYPE_MANAGER and
        // mock its getters here (incl. the bridgehub's baseTokenAssetId lookup).
        mockDiamondInitInteropCenterCallsWithAddress(
            address(dummyBridgehub),
            address(0),
            Utils.TEST_BASE_TOKEN_ASSET_ID
        );
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
