// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AuthoredL2Side, DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";
import {BytecodeUtils} from "deploy-scripts/utils/bytecode/BytecodeUtils.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {AuthoredL2Plan} from "contracts/upgrades/registry/RegistryTypes.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @dev A version that opts into the standard side, as `CTMUpgrade_v36` does. Sets the edge and exposes
///      the prepared plan. Nothing else of the prepare pipeline runs: preparing the L2 side depends only
///      on the edge, the composer and the CTM's `BytecodesSupplier`.
contract StandardL2SideHarness is DefaultCTMUpgrade {
    function setEdge(uint256 _oldProtocolVersion, uint256 _newProtocolVersion) external {
        newConfig.oldProtocolVersion = _oldProtocolVersion;
        setNewProtocolVersion(_newProtocolVersion);
    }

    function setBytecodesSupplier(address _supplier) external {
        ctmAddresses.stateTransition.proxies.bytecodesSupplier = _supplier;
    }

    function setL2DelegateComposer(address _composer) external {
        l2DelegateComposer = _composer;
    }

    function preparedPlan() external view returns (AuthoredL2Plan memory) {
        return authoredL2Plan();
    }

    function authorL2Side() internal override returns (AuthoredL2Side memory) {
        return standardL2Side();
    }
}

/// @notice The standard L2 side (`L2DefaultUpgrade` through its composer) is what a minor edge of a
///         version that opts into it carries; on a same-minor edge it is the L1-only side, since a
///         patch cannot carry an L2 upgrade. See the Patches section of
///         {docs/registry-driven-upgrades.md}.
contract StandardL2SideTest is Test {
    uint32 internal constant MINOR = 36;

    StandardL2SideHarness internal harness;
    BytecodesSupplier internal supplier;

    function setUp() public {
        harness = new StandardL2SideHarness();
        supplier = new BytecodesSupplier();
        harness.setBytecodesSupplier(address(supplier));
    }

    // ─────────────────────────────── minor edge ───────────────────────────────

    /// @dev The composer is preset: deploying it needs the deterministic CREATE2 factory, which the
    ///      anvil upgrade test covers.
    function test_minorEdgeRunsL2DefaultUpgradeThroughThePinnedComposer() public {
        address composer = makeAddr("composer");
        harness.setL2DelegateComposer(composer);
        harness.setEdge(SemVer.packSemVer(0, MINOR - 1, 0), SemVer.packSemVer(0, MINOR, 0));

        harness.prepareL2Side();

        AuthoredL2Plan memory plan = harness.preparedPlan();
        assertEq(
            plan.delegateBytecodeInfo,
            Utils.getZKOSBytecodeInfoForContract("L2DefaultUpgrade.sol", "L2DefaultUpgrade"),
            "the delegate is L2DefaultUpgrade"
        );
        assertEq(plan.extraBytecodeInfos.length, 0, "no extras");
        assertEq(plan.delegateComposer, composer, "the pinned composer");
        bytes memory delegateCode = BytecodeUtils.readDeployedBytecodeL1("L2DefaultUpgrade.sol", "L2DefaultUpgrade");
        assertTrue(supplier.evmPublishingBlock(keccak256(delegateCode)) != 0, "the delegate is published");
    }

    // ─────────────────────────────── same-minor edge ───────────────────────────────

    /// @dev Covers the patch edges and the infrastructure-only edge (`_oldPatch == _newPatch`). The
    ///      composer stays undeployed: the patch never reaches the deployment.
    function testFuzz_sameMinorEdgeIsL1Only(uint32 _oldPatch, uint32 _newPatch) public {
        harness.setEdge(SemVer.packSemVer(0, MINOR, _oldPatch), SemVer.packSemVer(0, MINOR, _newPatch));

        vm.recordLogs();
        harness.prepareL2Side();
        assertEq(vm.getRecordedLogs().length, 0, "a same-minor edge publishes nothing");

        AuthoredL2Plan memory plan = harness.preparedPlan();
        assertEq(plan.delegateBytecodeInfo.length, 0, "no delegate");
        assertEq(plan.extraBytecodeInfos.length, 0, "no extras");
        assertEq(plan.delegateComposer, address(0), "no composer");
        assertEq(harness.l2DelegateComposer(), address(0), "the composer is not deployed");
    }
}
