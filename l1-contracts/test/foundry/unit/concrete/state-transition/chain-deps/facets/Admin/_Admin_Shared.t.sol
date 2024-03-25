// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";

import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";

contract AdminTest is Test {
    IAdmin internal adminFacet;
    UtilsFacet internal utilsFacet;
    address internal testnetVerifier = address(new TestnetVerifier());

    function getAdminSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = IAdmin.setPendingAdmin.selector;
        selectors[1] = IAdmin.acceptAdmin.selector;
        selectors[2] = IAdmin.setValidator.selector;
        selectors[3] = IAdmin.setPorterAvailability.selector;
        selectors[4] = IAdmin.setPriorityTxMaxGasLimit.selector;
        selectors[5] = IAdmin.changeFeeParams.selector;
        selectors[6] = IAdmin.setTokenMultiplier.selector;
        selectors[7] = IAdmin.upgradeChainFromVersion.selector;
        selectors[8] = IAdmin.executeUpgrade.selector;
        selectors[9] = IAdmin.freezeDiamond.selector;
        selectors[10] = IAdmin.unfreezeDiamond.selector;
        selectors[11] = IAdmin.setTransactionFilterer.selector;
        return selectors;
    }

    function setUp() public virtual {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new AdminFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getAdminSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });

        address diamondProxy = Utils.makeDiamondProxy(facetCuts, testnetVerifier);
        adminFacet = IAdmin(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
