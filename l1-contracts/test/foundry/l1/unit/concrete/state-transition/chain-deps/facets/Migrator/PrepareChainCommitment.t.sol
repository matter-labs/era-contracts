// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MigratorTest} from "./_Migrator_Shared.t.sol";
import {ZKChainCommitment} from "contracts/common/Config.sol";
import {ExecutedIsNotConsistentWithVerified, VerifiedIsNotConsistentWithCommitted} from "contracts/state-transition/L1StateTransitionErrors.sol";

contract PrepareChainCommitmentTest is MigratorTest {
    function test_prepareChainCommitment_RevertWhen_ExecutedExceedsVerified() public {
        // Set up inconsistent batch counts where executed > verified
        utilsFacet.util_setTotalBatchesExecuted(10);
        utilsFacet.util_setTotalBatchesVerified(5);
        utilsFacet.util_setTotalBatchesCommitted(15);

        vm.expectRevert(abi.encodeWithSelector(ExecutedIsNotConsistentWithVerified.selector, 10, 5));
        migratorFacet.prepareChainCommitment();
    }

    function test_prepareChainCommitment_RevertWhen_VerifiedExceedsCommitted() public {
        // Set up inconsistent batch counts where verified > committed
        utilsFacet.util_setTotalBatchesExecuted(5);
        utilsFacet.util_setTotalBatchesVerified(15);
        utilsFacet.util_setTotalBatchesCommitted(10);

        vm.expectRevert(abi.encodeWithSelector(VerifiedIsNotConsistentWithCommitted.selector, 15, 10));
        migratorFacet.prepareChainCommitment();
    }

    function test_prepareChainCommitment_Success() public {
        // Set up consistent batch counts
        utilsFacet.util_setTotalBatchesExecuted(5);
        utilsFacet.util_setTotalBatchesVerified(8);
        utilsFacet.util_setTotalBatchesCommitted(10);

        ZKChainCommitment memory commitment = migratorFacet.prepareChainCommitment();

        assertEq(commitment.totalBatchesExecuted, 5);
        assertEq(commitment.totalBatchesVerified, 8);
        assertEq(commitment.totalBatchesCommitted, 10);
        // batchHashes length should be committed - executed + 1 = 10 - 5 + 1 = 6
        assertEq(commitment.batchHashes.length, 6);
    }

    function test_prepareChainCommitment_IncludesAllFields() public {
        // Set up chain state
        utilsFacet.util_setTotalBatchesExecuted(2);
        utilsFacet.util_setTotalBatchesVerified(3);
        utilsFacet.util_setTotalBatchesCommitted(4);
        utilsFacet.util_setL2SystemContractsUpgradeBatchNumber(100);

        bytes32 upgradeTxHash = keccak256("upgradeTxHash");
        utilsFacet.util_setL2SystemContractsUpgradeTxHash(upgradeTxHash);

        ZKChainCommitment memory commitment = migratorFacet.prepareChainCommitment();

        assertEq(commitment.totalBatchesExecuted, 2);
        assertEq(commitment.totalBatchesVerified, 3);
        assertEq(commitment.totalBatchesCommitted, 4);
        assertEq(commitment.l2SystemContractsUpgradeBatchNumber, 100);
        assertEq(commitment.l2SystemContractsUpgradeTxHash, upgradeTxHash);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
