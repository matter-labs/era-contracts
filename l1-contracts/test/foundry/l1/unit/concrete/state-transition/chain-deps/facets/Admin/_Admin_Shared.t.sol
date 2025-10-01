// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
    address internal testnetVerifier =
        address(new TestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0)), address(0)));

    function getAdminSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](14);
        uint256 i = 0;
        selectors[i++] = IAdmin.setPendingAdmin.selector;
        selectors[i++] = IAdmin.acceptAdmin.selector;
        selectors[i++] = IAdmin.setValidator.selector;
        selectors[i++] = IAdmin.setPorterAvailability.selector;
        selectors[i++] = IAdmin.setPriorityTxMaxGasLimit.selector;
        selectors[i++] = IAdmin.changeFeeParams.selector;
        selectors[i++] = IAdmin.setTokenMultiplier.selector;
        selectors[i++] = IAdmin.upgradeChainFromVersion.selector;
        selectors[i++] = IAdmin.executeUpgrade.selector;
        selectors[i++] = IAdmin.freezeDiamond.selector;
        selectors[i++] = IAdmin.unfreezeDiamond.selector;
        selectors[i++] = IAdmin.setTransactionFilterer.selector;
        selectors[i++] = IAdmin.setPubdataPricingMode.selector;
        selectors[i++] = IAdmin.setDAValidatorPair.selector;
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
