// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {PinnedRegistryObject} from "deploy-scripts/upgrade/default-upgrade/PinnedRegistryObject.sol";

/// @dev Exposes the reuse predicate. Nothing else of the prepare pipeline runs: the predicate
///      depends only on the build artifacts and this run's constructor arguments.
contract ReleaseMemberReuseHarness is DefaultCTMUpgrade {
    function canReuseReleaseMember(string memory _name, address _live) public returns (bool) {
        return _canReuseReleaseMember(_name, _live);
    }
}

/// @notice The rule that lets a small upgrade deploy only what it changes: a live release member is
///         reused when — and only when — it already runs the code this prepare would deploy. See
///         "reduce preparation for small changes" in {docs/upgrade-script-retirement.md}.
contract ReleaseMemberReuseTest is Test {
    ReleaseMemberReuseHarness internal harness;

    function setUp() public {
        harness = new ReleaseMemberReuseHarness();
    }

    /// @dev Deploys an artifact locally (plain CREATE, never broadcast) — the same technique the
    ///      predicate itself uses to learn what the current sources produce.
    function _deployFromArtifact(
        string memory _fileName,
        string memory _contractName,
        bytes memory _args
    ) private returns (address deployed) {
        bytes memory initCode = abi.encodePacked(PinnedRegistryObject.creationCode(_fileName, _contractName), _args);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "artifact deployment failed");
    }

    /// @dev A member already running the code this prepare would deploy is kept, so the upgrade's
    ///      deployment list does not contain it and no chain sees a facet cut for it.
    function test_reusesAMemberRunningTheCodeThisPrepareWouldDeploy() public {
        address live = _deployFromArtifact("Executor.sol", "ExecutorFacet", "");
        assertTrue(harness.canReuseReleaseMember("ExecutorFacet", live), "identical code must be reused");
    }

    /// @dev Code identity decides it, not the inventory slot: another contract in the member's
    ///      place is replaced.
    function test_replacesAMemberRunningDifferentCode() public {
        address live = _deployFromArtifact("Getters.sol", "GettersFacet", "");
        assertFalse(harness.canReuseReleaseMember("ExecutorFacet", live), "different code must be replaced");
    }

    /// @dev Nothing live to reuse: a fresh deployment, or an inventory slot the live release never
    ///      filled.
    function test_deploysWhenThereIsNoLiveMember() public {
        assertFalse(harness.canReuseReleaseMember("ExecutorFacet", address(0)), "a zero member must be deployed");
        assertFalse(
            harness.canReuseReleaseMember("ExecutorFacet", address(0xdead)),
            "a codeless member must be deployed"
        );
    }

    /// @dev Why the predicate DEPLOYS a probe instead of comparing artifacts: a member whose code
    ///      carries immutables has those slots ZEROED in the artifact's `deployedBytecode`, so the
    ///      artifact's codehash never equals the live one. `DiamondInit` pins its VM flag that way.
    function test_reusesAnImmutableCarryingMemberTheArtifactCannotDescribe() public {
        address live = _deployFromArtifact("DiamondInit.sol", "DiamondInit", abi.encode(true));
        assertTrue(harness.canReuseReleaseMember("DiamondInit", live), "identical code must be reused");
        assertTrue(
            live.codehash != PinnedRegistryObject.codehash("DiamondInit.sol", "DiamondInit"),
            "an artifact comparison would have called this member changed"
        );
    }
}
