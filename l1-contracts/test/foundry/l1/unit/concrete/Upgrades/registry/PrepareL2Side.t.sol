// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AuthoredL2Side, DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {AuthoredL2Plan, PinnedContract} from "contracts/upgrades/registry/RegistryTypes.sol";
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
///         bytecodes on the CTM's supplier and pins their hashes as the plan's factory
///         dependencies — the plan can never name a hash nobody published, and an L1-only edge
///         publishes nothing.
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
        assertEq(plan.extraDeployments.length, 0, "no extras");
        assertEq(plan.delegateTo, address(0), "no delegate");
        assertEq(plan.delegateComposer.addr, address(0), "no composer");
        assertEq(plan.factoryDepHashes.length, 0, "no factory dependencies");
    }

    /// @dev The authored list names the delegate twice: publication deduplicates, keeping the
    ///      first occurrence's position, so the pinned hashes are exactly the published set.
    function test_publishesExactlyTheListedBytecodesAndPinsTheirHashes() public {
        AuthoredL2Side memory side = _authoredSide();
        harness.setSide(side);
        harness.prepareL2Side();

        assertTrue(supplier.evmPublishingBlock(keccak256(DELEGATE_CODE)) != 0, "the delegate is published");
        assertTrue(supplier.evmPublishingBlock(keccak256(BUILT_IN_CODE)) != 0, "the built-in is published");

        AuthoredL2Plan memory plan = harness.preparedPlan();
        assertEq(
            plan.factoryDepHashes,
            L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE, BUILT_IN_CODE)),
            "the plan pins exactly the published bytecodes, once each, in authored order"
        );
        // The authored fields ride through untouched.
        assertEq(plan.extraDeployments.length, 1, "the authored extra");
        assertEq(plan.extraDeployments[0].newAddress, side.plan.extraDeployments[0].newAddress, "extra address");
        assertEq(plan.extraDeployments[0].deployedBytecodeInfo, side.plan.extraDeployments[0].deployedBytecodeInfo);
        assertEq(plan.delegateTo, side.plan.delegateTo, "delegate target");
        assertEq(plan.delegateComposer.addr, side.plan.delegateComposer.addr, "composer");
        assertEq(plan.delegateComposer.codehash, side.plan.delegateComposer.codehash, "composer pin");
    }

    function test_alreadyPublishedBytecodeIsPinnedWithoutRepublishing() public {
        L2PlanFixtures.publish(supplier, L2PlanFixtures.codes(DELEGATE_CODE));
        uint256 firstBlock = supplier.evmPublishingBlock(keccak256(DELEGATE_CODE));
        vm.roll(block.number + 1);

        harness.setSide(_authoredSide());
        harness.prepareL2Side();

        assertEq(supplier.evmPublishingBlock(keccak256(DELEGATE_CODE)), firstBlock, "the delegate is not republished");
        assertEq(supplier.evmPublishingBlock(keccak256(BUILT_IN_CODE)), block.number, "the built-in is published now");
        assertEq(
            harness.preparedPlan().factoryDepHashes,
            L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE, BUILT_IN_CODE)),
            "both are pinned regardless of who published them"
        );
    }

    // ─────────────────────────────── unhappy paths ───────────────────────────────

    function test_revertWhen_sideAuthorsFactoryDependencyHashes() public {
        AuthoredL2Side memory side = _authoredSide();
        side.plan.factoryDepHashes = L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE));
        harness.setSide(side);

        vm.expectRevert(bytes("factory dependency hashes are derived from the published bytecodes, not authored"));
        harness.prepareL2Side();
    }

    function test_revertWhen_planIsReadBeforePreparation() public {
        vm.expectRevert(bytes("L2 side not prepared"));
        harness.preparedPlan();
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    /// @dev The shape a version with an L2 leg authors: the delegate as an Unsafe extra at its
    ///      bytecode-derived address, a pinned composer, and the bytecodes to publish — the
    ///      delegate's, a built-in's, and the delegate's again.
    function _authoredSide() internal returns (AuthoredL2Side memory side) {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory extras = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        extras[0] = L2PlanFixtures.unsafeDeployment(DELEGATE_CODE);
        address composer = makeAddr("composer");
        vm.etch(composer, hex"6000fe");
        side.plan = AuthoredL2Plan({
            extraDeployments: extras,
            delegateTo: extras[0].newAddress,
            delegateComposer: PinnedContract({addr: composer, codehash: composer.codehash}),
            factoryDepHashes: new uint256[](0)
        });
        side.factoryDependencies = new bytes[](3);
        side.factoryDependencies[0] = DELEGATE_CODE;
        side.factoryDependencies[1] = BUILT_IN_CODE;
        side.factoryDependencies[2] = DELEGATE_CODE;
    }
}
