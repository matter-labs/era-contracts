// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";

import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {NotSettlementLayer} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {GW_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";

contract ZKChainBaseModifiersTest is UtilsCallMockerTest {
    IAdmin internal adminFacet;
    IExecutor internal executorFacet;
    IMailbox internal mailboxFacet;
    UtilsFacet internal utilsFacet;
    DummyBridgehub internal dummyBridgehub;
    address internal testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    uint256 constant eraChainId = 9;

    function getAdminSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](18);
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
        selectors[i++] = IAdmin.pauseDepositsBeforeInitiatingMigration.selector;
        selectors[i++] = IAdmin.unpauseDeposits.selector;
        selectors[i++] = IAdmin.setTransactionFilterer.selector;
        selectors[i++] = IAdmin.setPubdataPricingMode.selector;
        selectors[i++] = IAdmin.setDAValidatorPair.selector;
        selectors[i++] = IAdmin.getRollupDAManager.selector;
        selectors[i++] = IAdmin.makePermanentRollup.selector;
        return selectors;
    }

    function setUp() public {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](4);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new AdminFacet(block.chainid, RollupDAManager(address(0)), false)),
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
        facetCuts[2] = Diamond.FacetCut({
            facet: address(new ExecutorFacet(block.chainid)),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getExecutorSelectors()
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: address(
                new MailboxFacet(
                    eraChainId,
                    block.chainid,
                    address(0),
                    IEIP7702Checker(makeAddr("eip7702Checker")),
                    false
                )
            ),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: Utils.getMailboxSelectors()
        });

        dummyBridgehub = new DummyBridgehub();
        mockDiamondInitInteropCenterCallsWithAddress(address(dummyBridgehub), address(0), bytes32(0));
        mockChainTypeManagerVerifier(testnetVerifier);
        address diamondProxy = Utils.makeDiamondProxy(facetCuts, testnetVerifier, address(dummyBridgehub));
        adminFacet = IAdmin(diamondProxy);
        executorFacet = IExecutor(diamondProxy);
        mailboxFacet = IMailbox(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);
    }

    // Test onlySettlementLayer modifier revert
    function test_RevertWhen_makePermanentRollupNotSettlementLayer() public {
        address admin = utilsFacet.util_getAdmin();

        // Set settlement layer to non-zero address to trigger the revert
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));

        vm.prank(admin);
        vm.expectRevert(NotSettlementLayer.selector);
        adminFacet.makePermanentRollup();
    }

    // Test that onlySettlementLayer passes when settlementLayer is zero
    function test_onlySettlementLayerPassesWhenZero() public {
        // By default, settlementLayer is address(0), so the modifier should pass
        address settlementLayer = utilsFacet.util_getSettlementLayer();
        assertEq(settlementLayer, address(0), "Settlement layer should be zero by default");
    }
}
