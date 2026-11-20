// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Call} from "contracts/governance/Common.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";

import {CTMUpgrade_v36} from "deploy-scripts/upgrade/v36/CTMUpgrade_v36.s.sol";
import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";

/// @notice Exposes the v36 prepare's RollupDAManager handover over a given CTM and manager, without
///         the rest of the prepare.
contract RollupDAManagerHandoverHarness is CTMUpgrade_v36 {
    function declareFor(address _ctm, address _rollupDAManager) external {
        ctmAddresses.stateTransition.proxies.chainTypeManager = _ctm;
        ctmAddresses.daAddresses.daContracts.rollupDAManager = _rollupDAManager;
        declareRollupDAManagerHandover();
    }
}

/// @notice The v36 governance bundle hands the CTM's RollupDAManager to the CTM executor, so a release
///         engine can call `updateDAPair`. Runs the declared calls as the CTM executor's owner.
contract RollupDAManagerHandoverTest is CTMUpgradeExecutorFixture {
    RollupDAManagerHandoverHarness internal harness;
    RollupDAManager internal manager;

    function setUp() public override {
        super.setUp();
        harness = new RollupDAManagerHandoverHarness();
        manager = new RollupDAManager();
    }

    function test_governanceOwnedManagerIsHandedToTheExecutor() public {
        manager.transferOwnership(governor);
        vm.prank(governor);
        manager.acceptOwnership();

        Call[] memory calls = _declare();
        assertEq(calls.length, 2, "nominate, then accept through forward");
        _executeAsGovernance(calls);

        assertEq(manager.owner(), address(ctmExecutor), "the CTM executor owns the manager");
        assertEq(manager.pendingOwner(), address(0));
        _assertExecutorUpdatesDAPairs();
    }

    function test_pendingGovernanceNominationIsAcceptedFirst() public {
        manager.transferOwnership(governor);

        Call[] memory calls = _declare();
        assertEq(calls.length, 3, "accept the nomination, nominate, accept through forward");
        _executeAsGovernance(calls);

        assertEq(manager.owner(), address(ctmExecutor));
        assertEq(manager.pendingOwner(), address(0));
    }

    /// @dev A v0.36.x patch departs from a CTM whose executor already holds the manager.
    function test_executorOwnedManagerDeclaresNothing() public {
        manager.transferOwnership(address(ctmExecutor));
        vm.prank(address(ctmExecutor));
        manager.acceptOwnership();

        assertEq(_declare().length, 0);
    }

    /// @dev A CTM deployed with its own governance: the bundle's signer cannot move the manager.
    function test_managerOfAnotherOwnerDeclaresNothing() public {
        address otherGovernance = makeAddr("otherGovernance");
        manager.transferOwnership(otherGovernance);

        assertEq(_declare().length, 0);
        assertEq(manager.owner(), address(this), "nothing moved");
    }

    function test_revertWhen_theManagerIsUnknown() public {
        vm.expectRevert("the CTM's RollupDAManager is unknown");
        harness.declareFor(address(chainContractAddress), address(0));
    }

    function _declare() internal returns (Call[] memory) {
        harness.declareFor(address(chainContractAddress), address(manager));
        return harness.prepareGovernanceCalls();
    }

    function _executeAsGovernance(Call[] memory _calls) internal {
        for (uint256 i = 0; i < _calls.length; ++i) {
            vm.prank(governor);
            (bool success, bytes memory returnData) = _calls[i].target.call{value: _calls[i].value}(_calls[i].data);
            if (!success) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
    }

    /// @dev What the handover is for: the executor (hence a release engine) can now set DA pairs.
    function _assertExecutorUpdatesDAPairs() internal {
        address validator = makeAddr("l1DAValidator");
        vm.prank(address(ctmExecutor));
        manager.updateDAPair(validator, L2DACommitmentScheme.BLOBS_ZKSYNC_OS, true);
        assertTrue(manager.isPairAllowed(validator, L2DACommitmentScheme.BLOBS_ZKSYNC_OS));

        vm.prank(governor);
        vm.expectRevert("Ownable: caller is not the owner");
        manager.updateDAPair(validator, L2DACommitmentScheme.BLOBS_ZKSYNC_OS, false);
    }
}
