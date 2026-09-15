// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AuthoredL2Side, DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {AuthoredL2Plan} from "contracts/upgrades/registry/RegistryTypes.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";

/// @dev Substitutes the authored side and exposes the prepared plan. Nothing else of the prepare
///      pipeline runs: preparing the L2 side depends only on the authored side and the CTM's
///      `BytecodesSupplier`.
contract PrepareL2SideHarness is DefaultCTMUpgrade {
    bytes internal encodedSide;
    bool internal sideSet;

    function setSide(AuthoredL2Side memory _side) external {
        encodedSide = abi.encode(_side);
        sideSet = true;
    }

    function setBytecodesSupplier(address _supplier) external {
        ctmAddresses.stateTransition.proxies.bytecodesSupplier = _supplier;
    }

    function preparedPlan() external view returns (AuthoredL2Plan memory) {
        return authoredL2Plan();
    }

    function l2SidePrepared() external view returns (bool) {
        return upgradeConfig.l2SidePrepared;
    }

    function authorL2Side() internal override returns (AuthoredL2Side memory) {
        if (!sideSet) {
            return DefaultCTMUpgrade.authorL2Side();
        }
        return abi.decode(encodedSide, (AuthoredL2Side));
    }
}

/// @notice A version contributes ONE result to the L2 side of its edge: the authored plan plus the
///         bytecodes that plan needs (see `AuthoredL2Side`). The prepare publishes exactly those
///         bytecodes on the CTM's supplier and pins the authored plan as is — the object constructs
///         the factory dependencies itself and refuses to commit until they are published — and an
///         L1-only edge publishes nothing.
contract PrepareL2SideTest is Test {
    bytes internal constant DELEGATE_CODE = hex"de1e";
    bytes internal constant BUILT_IN_CODE = hex"b0b1";

    PrepareL2SideHarness internal harness;
    BytecodesSupplier internal supplier;

    function setUp() public {
        harness = new PrepareL2SideHarness();
        supplier = new BytecodesSupplier();
        harness.setBytecodesSupplier(address(supplier));
    }

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_l1OnlyDefaultPublishesNothingAndPinsAnEmptyPlan() public {
        vm.recordLogs();
        harness.prepareL2Side();
        assertEq(vm.getRecordedLogs().length, 0, "an L1-only edge publishes nothing");
        assertTrue(harness.l2SidePrepared(), "the side is prepared");

        AuthoredL2Plan memory plan = harness.preparedPlan();
        assertEq(plan.delegateBytecodeInfo.length, 0, "no delegate");
        assertEq(plan.extraBytecodeInfos.length, 0, "no extras");
        assertEq(plan.delegateComposer, address(0), "no composer");
    }

    /// @dev The authored list names the delegate twice: publication deduplicates, so each listed
    ///      bytecode is published exactly once.
    function test_publishesExactlyTheListedBytecodesAndPinsThePlanAsAuthored() public {
        AuthoredL2Side memory side = _authoredSide();
        harness.setSide(side);
        vm.recordLogs();
        harness.prepareL2Side();

        assertEq(vm.getRecordedLogs().length, 2, "each listed bytecode is published once");
        assertTrue(supplier.evmPublishingBlock(keccak256(DELEGATE_CODE)) != 0, "the delegate is published");
        assertTrue(supplier.evmPublishingBlock(keccak256(BUILT_IN_CODE)) != 0, "the built-in is published");

        // The authored fields ride through untouched.
        AuthoredL2Plan memory plan = harness.preparedPlan();
        assertEq(plan.delegateBytecodeInfo, side.plan.delegateBytecodeInfo, "delegate bytecode info");
        assertEq(plan.extraBytecodeInfos.length, 0, "no extras");
        assertEq(plan.delegateComposer, side.plan.delegateComposer, "composer");
        assertEq(plan.delegateComposer.codehash, side.plan.delegateComposer.codehash, "composer pin");
    }

    function test_alreadyPublishedBytecodeIsNotRepublished() public {
        L2PlanFixtures.publish(supplier, L2PlanFixtures.codes(DELEGATE_CODE));
        uint256 firstBlock = supplier.evmPublishingBlock(keccak256(DELEGATE_CODE));
        vm.roll(block.number + 1);

        harness.setSide(_authoredSide());
        harness.prepareL2Side();

        assertEq(supplier.evmPublishingBlock(keccak256(DELEGATE_CODE)), firstBlock, "the delegate is not republished");
        assertEq(supplier.evmPublishingBlock(keccak256(BUILT_IN_CODE)), block.number, "the built-in is published now");
    }

    // ─────────────────────────────── unhappy paths ───────────────────────────────

    function test_revertWhen_planIsReadBeforePreparation() public {
        vm.expectRevert(bytes("L2 side not prepared"));
        harness.preparedPlan();
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    /// @dev The shape a version with an L2 leg authors: the delegate's bytecode info, a pinned
    ///      composer, and the bytecodes to publish — the delegate's, a built-in's, and the
    ///      delegate's again.
    function _authoredSide() internal returns (AuthoredL2Side memory side) {
        address composer = makeAddr("composer");
        vm.etch(composer, hex"6000fe");
        side.plan = L2PlanFixtures.delegatePlan(DELEGATE_CODE, composer);
        side.factoryDependencies = new bytes[](3);
        side.factoryDependencies[0] = DELEGATE_CODE;
        side.factoryDependencies[1] = BUILT_IN_CODE;
        side.factoryDependencies[2] = DELEGATE_CODE;
    }
}
