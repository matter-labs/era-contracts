// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2PlanLib} from "contracts/upgrades/registry/libraries/L2PlanLib.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {L2PlanDelegateNeedsComposer, L2PlanNeedsDelegate} from "contracts/common/L1ContractErrors.sol";
import {AuthoredL2Plan, L2UpgradePlan} from "contracts/upgrades/registry/RegistryTypes.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";

/// @dev Exposes the internal builder, so its shape rules are tested on their own; the objects that
///      call it (`CTMTransition`, `RegistryBootstrapMigration`) test the same rules at construction.
contract L2PlanLibHarness {
    function build(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _derived,
        AuthoredL2Plan memory _authored
    ) external pure returns (L2UpgradePlan memory) {
        return L2PlanLib.build(_derived, _authored);
    }
}

/// @notice The shape rules of the final L2 plan: a delegate and a composer come together or not at
///         all, and deployments need the delegate. See {L2PlanLib.build}.
contract L2PlanLibTest is Test {
    L2PlanLibHarness internal harness;
    address internal composer;

    bytes internal constant DELEGATE_CODE = hex"de1e";
    bytes internal constant EXTRA_CODE = hex"e0e0";
    bytes internal constant TABLE_IMPL_CODE = hex"7a01";
    bytes internal constant TABLE_SHELL_CODE = hex"7a02";
    /// @dev Where the table-derived system-proxy row installs; the builder copies it verbatim.
    address internal constant TABLE_MEMBER_ADDRESS = address(0x10010);

    function setUp() public {
        harness = new L2PlanLibHarness();
        composer = makeAddr("composer");
    }

    // ─────────────────────────────── happy paths ───────────────────────────────

    /// @dev The derived row first, then the delegate at its bytecode-derived address; the composer
    ///      rides through and every installed bytecode is a factory dependency.
    function test_build_delegateWithComposer() public view {
        L2UpgradePlan memory plan = harness.build(_derivedRow(), L2PlanFixtures.delegatePlan(DELEGATE_CODE, composer));

        IComplexUpgrader.UniversalContractUpgradeInfo memory delegate = L2PlanFixtures.unsafeDeployment(DELEGATE_CODE);
        assertEq(plan.deployments.length, 2, "the derived row and the delegate");
        assertEq(abi.encode(plan.deployments[0]), abi.encode(_derivedRow()[0]), "the derived row comes first");
        assertEq(abi.encode(plan.deployments[1]), abi.encode(delegate), "then the delegate");
        assertEq(plan.delegateTo, delegate.newAddress, "the delegate target is the delegate's derived address");
        assertEq(plan.delegateComposer, composer, "the composer rides through");
        assertEq(
            abi.encode(plan.factoryDepHashes),
            abi.encode(
                L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(TABLE_IMPL_CODE, TABLE_SHELL_CODE, DELEGATE_CODE))
            ),
            "every installed bytecode is a factory dependency"
        );
    }

    /// @dev An L1-only edge: nothing derived, nothing authored, an empty plan with no composer.
    function test_build_emptyPlanHasNoComposer() public view {
        L2UpgradePlan memory plan = harness.build(_noDerived(), L2PlanFixtures.emptyPlan());

        assertEq(plan.deployments.length, 0, "no deployments");
        assertEq(plan.delegateTo, address(0), "no delegate");
        assertEq(plan.delegateComposer, address(0), "no composer");
        assertEq(plan.factoryDepHashes.length, 0, "no factory dependencies");
    }

    // ─────────────────────────────── unhappy paths ───────────────────────────────

    /// @dev Without a composer the delegate would be called with empty calldata, which
    ///      `L2DefaultUpgrade` rejects (see `ComposedL2UpgradeTxExecution.t.sol`).
    function test_revertWhen_delegateWithoutComposer() public {
        vm.expectRevert(L2PlanDelegateNeedsComposer.selector);
        harness.build(_noDerived(), L2PlanFixtures.delegatePlan(DELEGATE_CODE, address(0)));
    }

    /// @dev Extras and derived rows do not change the rule.
    function test_revertWhen_delegateWithExtraAndDerivedRowsWithoutComposer() public {
        vm.expectRevert(L2PlanDelegateNeedsComposer.selector);
        harness.build(_derivedRow(), L2PlanFixtures.delegatePlanWithExtra(DELEGATE_CODE, EXTRA_CODE, address(0)));
    }

    /// @dev The pre-existing rule still fires with its own error: code defining calldata for a
    ///      delegate call that never happens.
    function test_revertWhen_composerWithoutDelegate() public {
        AuthoredL2Plan memory authored = L2PlanFixtures.emptyPlan();
        authored.delegateComposer = composer;

        vm.expectRevert(L2PlanNeedsDelegate.selector);
        harness.build(_noDerived(), authored);
    }

    /// @dev Derived deployments with neither a delegate nor a composer: the deployments rule fires.
    function test_revertWhen_derivedDeploymentsWithoutDelegate() public {
        vm.expectRevert(L2PlanNeedsDelegate.selector);
        harness.build(_derivedRow(), L2PlanFixtures.emptyPlan());
    }

    // ─────────────────────────────── fuzz ───────────────────────────────

    /// @dev Over every (delegate?, composer) pair with nothing else in the plan: it builds exactly
    ///      when the composer is set iff the delegate is, and otherwise reverts with the rule that
    ///      names the missing half.
    function testFuzz_build_composerIsSetExactlyWithADelegate(bool _withDelegate, address _composer) public {
        AuthoredL2Plan memory authored = _withDelegate
            ? L2PlanFixtures.delegatePlan(DELEGATE_CODE, _composer)
            : L2PlanFixtures.emptyPlan();
        authored.delegateComposer = _composer;
        bool hasComposer = _composer != address(0);

        if (_withDelegate != hasComposer) {
            vm.expectRevert(_withDelegate ? L2PlanDelegateNeedsComposer.selector : L2PlanNeedsDelegate.selector);
            harness.build(_noDerived(), authored);
            return;
        }
        L2UpgradePlan memory plan = harness.build(_noDerived(), authored);
        assertEq(plan.delegateComposer, _composer, "the composer rides through");
        assertEq(plan.deployments.length, _withDelegate ? 1 : 0, "the delegate is the only deployment");
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _noDerived() internal pure returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory) {
        return new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
    }

    /// @dev One table-derived system-proxy row, the shape `TransitionDerivationLib` produces.
    function _derivedRow() internal pure returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory rows) {
        rows = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        rows[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
            deployedBytecodeInfo: L2PlanFixtures.systemProxyRow(TABLE_IMPL_CODE, TABLE_SHELL_CODE),
            newAddress: TABLE_MEMBER_ADDRESS
        });
    }
}
