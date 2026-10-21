// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {ProofSystem, ZKSYNC_OS_PLONK_VERIFICATION_TYPE} from "contracts/common/Config.sol";
import {NotMultiProofMode, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    NotSettlementLayer,
    SecondProofSystemAlreadyRequired
} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice The second proof system requirement on the Admin facet alone. The end-to-end flow with a real
/// Bridgehub is in `SecondProofSystemRequirement.t.sol`.
/// See {protocol-docs/interop-gating.md#second-proof-system-requirement}.
contract PermanentlyRequireSecondProofSystemTest is AdminTest {
    uint8 internal constant ZISK_DISABLED = uint8(1 << uint8(ProofSystem.Zisk));

    address internal admin;
    address internal governance;

    function setUp() public override {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        bytes4[] memory adminSelectors = new bytes4[](2);
        adminSelectors[0] = IAdmin.permanentlyRequireSecondProofSystem.selector;
        adminSelectors[1] = IAdmin.setProofSystemStatus.selector;
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new AdminFacet(block.chainid, RollupDAManager(address(0)))),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: adminSelectors
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });

        dummyBridgehub = new DummyBridgehub();
        mockDiamondInitInteropCenterCallsWithAddress(address(dummyBridgehub), address(0), bytes32(0));
        mockChainTypeManagerVerifier(testnetVerifier);
        address diamondProxy = Utils.makeDiamondProxy(facetCuts, address(dummyBridgehub));
        adminFacet = IAdmin(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);

        // The proof mode only depends on the disabled proof systems, so the sub-verifiers are never called.
        utilsFacet.util_setVerifier(
            IVerifier(address(new MultiProofVerifier(IVerifier(address(0)), IVerifier(address(0)))))
        );
        admin = utilsFacet.util_getAdmin();
        // `DummyBridgehub` has no owner: the mock stands in for the Bridgehub owner the facet reads.
        governance = makeAddr("governance");
        vm.mockCall(address(dummyBridgehub), abi.encodeCall(IOwnable.owner, ()), abi.encode(governance));
    }

    function test_permanentlyRequireSecondProofSystem() public {
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit IAdmin.SecondProofSystemRequired();
        vm.prank(admin);
        adminFacet.permanentlyRequireSecondProofSystem();

        assertTrue(utilsFacet.util_getSecondProofSystemRequired());
    }

    function test_permanentlyRequireSecondProofSystem_revertWhen_alreadyRequired() public {
        vm.prank(admin);
        adminFacet.permanentlyRequireSecondProofSystem();

        vm.prank(admin);
        vm.expectRevert(SecondProofSystemAlreadyRequired.selector);
        adminFacet.permanentlyRequireSecondProofSystem();
    }

    function test_permanentlyRequireSecondProofSystem_revertWhen_notMultiProofMode() public {
        vm.prank(admin);
        adminFacet.setProofSystemStatus(ProofSystem.Zisk, false);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotMultiProofMode.selector, ZKSYNC_OS_PLONK_VERIFICATION_TYPE));
        adminFacet.permanentlyRequireSecondProofSystem();

        assertFalse(utilsFacet.util_getSecondProofSystemRequired());
    }

    function test_permanentlyRequireSecondProofSystem_revertWhen_notAdmin() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governance));
        adminFacet.permanentlyRequireSecondProofSystem();
    }

    function test_permanentlyRequireSecondProofSystem_revertWhen_settlingOnGateway() public {
        utilsFacet.util_setSettlementLayer(makeAddr("gatewayChain"));

        vm.prank(admin);
        vm.expectRevert(NotSettlementLayer.selector);
        adminFacet.permanentlyRequireSecondProofSystem();
    }

    function test_setProofSystemStatus_afterRequirement_onlyGovernanceDisables() public {
        vm.prank(admin);
        adminFacet.permanentlyRequireSecondProofSystem();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, admin));
        adminFacet.setProofSystemStatus(ProofSystem.Zisk, false);

        vm.prank(governance);
        adminFacet.setProofSystemStatus(ProofSystem.Zisk, false);
        assertEq(utilsFacet.util_getDisabledProofSystems(), ZISK_DISABLED, "governance disabled ZiSK");

        // Re-enabling stays with the chain admin.
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governance));
        adminFacet.setProofSystemStatus(ProofSystem.Zisk, true);

        vm.prank(admin);
        adminFacet.setProofSystemStatus(ProofSystem.Zisk, true);
        assertEq(utilsFacet.util_getDisabledProofSystems(), 0, "admin re-enabled ZiSK");
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
