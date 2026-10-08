// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";

import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IInteropFeeManager} from "contracts/core/interop-fee/IInteropFeeManager.sol";
import {InsufficientInteropFeeBalance} from "contracts/core/interop-fee/InteropFeeErrors.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";

/// @notice Commit-time charging of the interop fee through a real diamond and a real `InteropFeeManager`.
/// See {protocol-docs/interop-fee.md}.
contract InteropFeeCommitTest is ExecutorTest {
    uint256 internal constant FEE_PER_UNIT = 0.001 ether;

    function setUp() public {}

    function test_commit_chargesFeePerUnit() public {
        _setFee(FEE_PER_UNIT);
        _fund(1 ether);

        vm.expectEmit(address(interopFeeManager));
        emit IInteropFeeManager.InteropFeeCharged(l2ChainId, 1, 3, 3 * FEE_PER_UNIT);
        _commit(_batchWithUnits(3), validator);

        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(interopFeeManager.chainBalance(l2ChainId), 1 ether - 3 * FEE_PER_UNIT);
        assertEq(interopFeeManager.accruedFees(), 3 * FEE_PER_UNIT);
    }

    function test_commit_unitsAreBoundIntoTheProofCommitment() public {
        CommitBatchInfoZKsyncOS memory batch = _batchWithUnits(3);
        IExecutor.StoredBatchInfo memory stored = _commitOSBatchGetStored(genesisStoredBatchInfo, batch);

        // The verifier checks this commitment, so a different `interopFeeUnits` than the proven one can't
        // be proven, let alone executed.
        assertEq(
            stored.commitment,
            keccak256(
                abi.encodePacked(
                    genesisStoredBatchInfo.batchHash,
                    batch.newStateCommitment,
                    batch.chainConfigHash,
                    _batchOutputHash(batch, bytes32(0))
                )
            )
        );
        batch.interopFeeUnits = 4;
        assertNotEq(
            stored.commitment,
            keccak256(
                abi.encodePacked(
                    genesisStoredBatchInfo.batchHash,
                    batch.newStateCommitment,
                    batch.chainConfigHash,
                    _batchOutputHash(batch, bytes32(0))
                )
            )
        );
    }

    function test_commit_switchOffChargesNothing() public {
        _fund(1 ether);

        vm.recordLogs();
        _commit(_batchWithUnits(3), validator);

        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(interopFeeManager.chainBalance(l2ChainId), 1 ether);
        assertEq(interopFeeManager.accruedFees(), 0);
        assertEq(_countFeeEvents(), 0);
    }

    function test_commit_withoutInteropDoesNotTouchTheManager() public {
        // No balance at all: a batch with no interop must still commit while the switch is on.
        _setFee(FEE_PER_UNIT);

        vm.expectCall(
            address(interopFeeManager),
            abi.encodeWithSelector(IInteropFeeManager.chargeInteropFee.selector),
            0
        );
        _commit(_batchWithUnits(0), validator);

        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(interopFeeManager.accruedFees(), 0);
    }

    function test_revertWhen_commitCannotPayTheFee() public {
        _setFee(FEE_PER_UNIT);
        _fund(2 * FEE_PER_UNIT);

        CommitBatchInfoZKsyncOS memory batch = _batchWithUnits(3);
        (uint256 from, uint256 to, bytes memory data) = _encode(batch);
        _mockDAForCommit(batch.batchNumber);
        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientInteropFeeBalance.selector,
                l2ChainId,
                2 * FEE_PER_UNIT,
                3 * FEE_PER_UNIT
            )
        );
        committer.commitBatchesSharedBridge(address(0), from, to, data);

        assertEq(getters.getTotalBatchesCommitted(), 0);
        assertEq(interopFeeManager.chainBalance(l2ChainId), 2 * FEE_PER_UNIT);
    }

    function test_commit_resumesAfterTopUp() public {
        _setFee(FEE_PER_UNIT);
        _fund(2 * FEE_PER_UNIT);

        CommitBatchInfoZKsyncOS memory batch = _batchWithUnits(3);
        (uint256 from, uint256 to, bytes memory data) = _encode(batch);
        _mockDAForCommit(batch.batchNumber);
        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientInteropFeeBalance.selector,
                l2ChainId,
                2 * FEE_PER_UNIT,
                3 * FEE_PER_UNIT
            )
        );
        committer.commitBatchesSharedBridge(address(0), from, to, data);

        // Anyone can top the chain up; the very same batch then commits.
        _fund(FEE_PER_UNIT);
        vm.prank(validator);
        committer.commitBatchesSharedBridge(address(0), from, to, data);

        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(interopFeeManager.chainBalance(l2ChainId), 0);
        assertEq(interopFeeManager.accruedFees(), 3 * FEE_PER_UNIT);
    }

    function test_commit_priorityModeIsNeverCharged() public {
        _setFee(FEE_PER_UNIT);
        _activatePriorityMode();

        // An L1-only batch can still send interop (an L1->L2 tx calling the InteropCenter). It commits through
        // the permissionless validator without any prepaid balance.
        CommitBatchInfoZKsyncOS memory batch = _batchWithUnits(5);
        batch.numberOfLayer1Txs = 1;
        vm.expectCall(
            address(interopFeeManager),
            abi.encodeWithSelector(IInteropFeeManager.chargeInteropFee.selector),
            0
        );
        _commit(batch, address(permissionlessValidator));

        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(interopFeeManager.accruedFees(), 0);
    }

    /// @dev Documented trade-off: a reverted batch's fee is not refunded, so re-committing the same interop
    /// pays again. See {protocol-docs/interop-fee.md}.
    function test_revertedBatchIsChargedAgainOnRecommit() public {
        _setFee(FEE_PER_UNIT);
        _fund(1 ether);

        _commit(_batchWithUnits(3), validator);
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);
        assertEq(getters.getTotalBatchesCommitted(), 0);

        _commit(_batchWithUnits(3), validator);

        assertEq(interopFeeManager.chainBalance(l2ChainId), 1 ether - 6 * FEE_PER_UNIT);
        assertEq(interopFeeManager.accruedFees(), 6 * FEE_PER_UNIT);
    }

    /// @dev A Committer on L1 without a manager would revert every interop commit even with the switch off.
    function test_revertWhen_committerOnL1HasNoFeeManager() public {
        vm.expectRevert(ZeroAddress.selector);
        new CommitterFacet(block.chainid, IInteropFeeManager(address(0)));
    }

    function test_committerOffL1NeedsNoFeeManager() public {
        CommitterFacet facet = new CommitterFacet(block.chainid + 1, IInteropFeeManager(address(0)));
        assertEq(facet.getInteropFeeManager(), address(0));
    }

    function test_getInteropFeeManager_returnsTheChargedManager() public view {
        assertEq(committer.getInteropFeeManager(), address(interopFeeManager));
    }

    function testFuzz_commit_chargesLinearlyInUnits(uint32 _units, uint64 _feePerUnit) public {
        _setFee(_feePerUnit);
        uint256 fee = uint256(_feePerUnit) * _units;
        if (fee != 0) {
            _fund(fee);
        }

        _commit(_batchWithUnits(_units), validator);

        assertEq(interopFeeManager.chainBalance(l2ChainId), 0);
        assertEq(interopFeeManager.accruedFees(), fee);
    }

    function _batchWithUnits(uint256 _units) internal view returns (CommitBatchInfoZKsyncOS memory batch) {
        batch = newCommitBatchInfoZKsyncOS;
        batch.interopFeeUnits = _units;
    }

    function _encode(
        CommitBatchInfoZKsyncOS memory _batch
    ) internal view returns (uint256 from, uint256 to, bytes memory data) {
        CommitBatchInfoZKsyncOS[] memory batches = new CommitBatchInfoZKsyncOS[](1);
        batches[0] = _batch;
        return Utils.encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, batches);
    }

    function _commit(CommitBatchInfoZKsyncOS memory _batch, address _sender) internal {
        (uint256 from, uint256 to, bytes memory data) = _encode(_batch);
        _mockDAForCommit(_batch.batchNumber);
        vm.prank(_sender);
        committer.commitBatchesSharedBridge(address(0), from, to, data);
    }

    function _setFee(uint256 _feePerUnit) internal {
        vm.prank(owner);
        interopFeeManager.setFeePerUnit(_feePerUnit);
    }

    function _fund(uint256 _amount) internal {
        address payer = makeAddr("operator");
        vm.deal(payer, _amount);
        vm.prank(payer);
        interopFeeManager.deposit{value: _amount}(l2ChainId);
    }

    function _countFeeEvents() internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == IInteropFeeManager.InteropFeeCharged.selector) {
                ++count;
            }
        }
    }
}
