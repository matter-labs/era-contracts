// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {Migrator} from "contracts/state-transition/chain-deps/facets/Migrator.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IMigrator} from "contracts/state-transition/chain-interfaces/IMigrator.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";

contract MigratorTest is UtilsCallMockerTest {
    IMigrator internal migratorFacet;
    UtilsFacet internal utilsFacet;
    address internal testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    DummyBridgehub internal dummyBridgehub;

    function getMigratorSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](6);
        uint256 i = 0;
        selectors[i++] = IMigrator.pauseDepositsBeforeInitiatingMigration.selector;
        selectors[i++] = IMigrator.unpauseDeposits.selector;
        selectors[i++] = IMigrator.forwardedBridgeBurn.selector;
        selectors[i++] = IMigrator.forwardedBridgeMint.selector;
        selectors[i++] = IMigrator.forwardedBridgeConfirmTransferResult.selector;
        selectors[i++] = IMigrator.prepareChainCommitment.selector;
        return selectors;
    }

    function setUp() public virtual {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new Migrator(block.chainid, false)),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getMigratorSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });

        dummyBridgehub = new DummyBridgehub();
        mockDiamondInitInteropCenterCallsWithAddress(address(dummyBridgehub), address(0), bytes32(0));
        address diamondProxy = Utils.makeDiamondProxy(facetCuts, testnetVerifier, address(dummyBridgehub));
        migratorFacet = IMigrator(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
