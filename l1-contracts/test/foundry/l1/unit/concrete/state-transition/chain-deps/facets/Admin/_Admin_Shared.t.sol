// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

contract AdminTest is Test {
    IAdmin internal adminFacet;
    UtilsFacet internal utilsFacet;
    address internal testnetVerifier = address(new TestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));

    function getAdminSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](13);
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
        selectors[12] = IAdmin.setPubdataPricingMode.selector;
        return selectors;
    }

    function setUp() public virtual {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new AdminFacet(block.chainid, RollupDAManager(address(0)))),
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
