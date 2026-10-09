// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IInteropFeeManager} from "contracts/core/interop-fee/IInteropFeeManager.sol";
import {InsufficientInteropFeeBalance} from "contracts/core/interop-fee/InteropFeeErrors.sol";
import {Unauthorized, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {DummyL2L1Messenger} from "contracts/dev-contracts/test/DummyL2L1Messenger.sol";

/// @notice The interop fee through a real diamond and a real `InteropFeeManager`: commits record each batch's count,
/// execution charges it, and the chain admin withdraws. See {protocol-docs/interop-fee.md}.
contract InteropFeeSettlementTest is ExecutorTest {
    uint256 internal constant FEE_PER_UNIT = 0.001 ether;

    function setUp() public {}

    function test_execute_chargesFeePerUnit() public {
        _setFee(FEE_PER_UNIT);
        _fund(1 ether);
        IExecutor.StoredBatchInfo memory stored = _commitAndProve(_batchWithUnits(3));

        vm.expectEmit(address(interopFeeManager));
        emit IInteropFeeManager.InteropFeeCharged(l2ChainId, 1, 3, 3 * FEE_PER_UNIT);
        _execute(stored);

        assertEq(getters.getTotalBatchesExecuted(), 1);
        assertEq(interopFeeManager.chainBalance(l2ChainId), 1 ether - 3 * FEE_PER_UNIT);
        assertEq(interopFeeManager.accruedFees(), 3 * FEE_PER_UNIT);
    }

    function test_commitAndProve_chargeNothing() public {
        // Switched on without a balance: committing and proving never depend on one.
        _setFee(FEE_PER_UNIT);

        vm.expectCall(
            address(interopFeeManager),
            abi.encodeWithSelector(IInteropFeeManager.chargeInteropFee.selector),
            0
        );
        _commitAndProve(_batchWithUnits(3));

        assertEq(getters.getTotalBatchesVerified(), 1);
    }

    function test_commit_unitsAreBoundIntoTheProofCommitment() public {
        uint256 snapshot = vm.snapshotState();
        bytes32 commitment = _commitOSBatchGetStored(genesisStoredBatchInfo, _batchWithUnits(3)).commitment;
        vm.revertToState(snapshot);
        assertNotEq(_commitOSBatchGetStored(genesisStoredBatchInfo, _batchWithUnits(4)).commitment, commitment);
    }

    function test_execute_switchOffChargesNothing() public {
        _fund(1 ether);

        _execute(_commitAndProve(_batchWithUnits(3)));

        assertEq(getters.getTotalBatchesExecuted(), 1);
        assertEq(interopFeeManager.chainBalance(l2ChainId), 1 ether);
        assertEq(interopFeeManager.accruedFees(), 0);
    }

    function test_execute_withoutInteropDoesNotTouchTheManager() public {
        // No balance at all: a batch with no interop must still execute while the switch is on.
        _setFee(FEE_PER_UNIT);
        IExecutor.StoredBatchInfo memory stored = _commitAndProve(_batchWithUnits(0));

        vm.expectCall(
            address(interopFeeManager),
            abi.encodeWithSelector(IInteropFeeManager.chargeInteropFee.selector),
            0
        );
        _execute(stored);

        assertEq(getters.getTotalBatchesExecuted(), 1);
    }

    function test_execute_revertsUntilToppedUp() public {
        _setFee(FEE_PER_UNIT);
        _fund(2 * FEE_PER_UNIT);
        IExecutor.StoredBatchInfo memory stored = _commitAndProve(_batchWithUnits(3));
        (uint256 from, uint256 to, bytes memory data) = _encodeExecute(stored);

        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsufficientInteropFeeBalance.selector,
                l2ChainId,
                2 * FEE_PER_UNIT,
                3 * FEE_PER_UNIT
            )
        );
        executor.executeBatchesSharedBridge(address(0), from, to, data);
        assertEq(getters.getTotalBatchesExecuted(), 0);
        assertEq(interopFeeManager.chainBalance(l2ChainId), 2 * FEE_PER_UNIT);

        // Anyone can top the chain up; the very same batch then executes.
        _fund(FEE_PER_UNIT);
        vm.prank(validator);
        executor.executeBatchesSharedBridge(address(0), from, to, data);

        assertEq(getters.getTotalBatchesExecuted(), 1);
        assertEq(interopFeeManager.chainBalance(l2ChainId), 0);
        assertEq(interopFeeManager.accruedFees(), 3 * FEE_PER_UNIT);
    }

    /// @dev The batch number committed again after the revert carries only its new count.
    function test_execute_revertedBatchIsNeverCharged() public {
        _setFee(FEE_PER_UNIT);
        _fund(1 ether);
        _commitAndProve(_batchWithUnits(3));
        vm.prank(validator);
        executor.revertBatchesSharedBridge(address(0), 0);

        IExecutor.StoredBatchInfo memory stored = _commitAndProve(_batchWithUnits(0));
        vm.expectCall(
            address(interopFeeManager),
            abi.encodeWithSelector(IInteropFeeManager.chargeInteropFee.selector),
            0
        );
        _execute(stored);

        assertEq(getters.getTotalBatchesExecuted(), 1);
        assertEq(interopFeeManager.chainBalance(l2ChainId), 1 ether);
        assertEq(interopFeeManager.accruedFees(), 0);
    }

    function test_revertWhen_executorOnL1HasNoFeeManager() public {
        vm.expectRevert(ZeroAddress.selector);
        new ExecutorFacet(block.chainid, IInteropFeeManager(address(0)));
    }

    function test_execute_offL1IsNeverCharged() public {
        // Switched on without a balance: a batch settled on a settlement layer other than L1 still executes.
        _setFee(FEE_PER_UNIT);
        vm.chainId(block.chainid + 1);
        // Off L1 the committer relays the committed batch to L1 through the messenger.
        vm.etch(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, address(new DummyL2L1Messenger()).code);
        CommitBatchInfoZKsyncOS memory batch = _batchWithUnits(3);
        batch.slChainId = block.chainid;
        IExecutor.StoredBatchInfo memory stored = _commitAndProve(batch);

        vm.expectCall(
            address(interopFeeManager),
            abi.encodeWithSelector(IInteropFeeManager.chargeInteropFee.selector),
            0
        );
        _execute(stored);

        assertEq(getters.getTotalBatchesExecuted(), 1);
    }

    function test_getInteropFeeManager_returnsTheChargedManager() public view {
        assertEq(executor.getInteropFeeManager(), address(interopFeeManager));
    }

    /// @dev The manager reads the chain admin from the diamond on every withdrawal, so it follows admin changes.
    function test_withdraw_byTheCurrentChainAdmin() public {
        _fund(1 ether);
        address to = makeAddr("withdrawalReceiver");
        address oldAdmin = getters.getAdmin();
        vm.prank(oldAdmin);
        interopFeeManager.withdraw(l2ChainId, to, 0.4 ether);

        address newAdmin = makeAddr("newChainAdmin");
        vm.prank(oldAdmin);
        admin.setPendingAdmin(newAdmin);
        vm.prank(newAdmin);
        admin.acceptAdmin();

        vm.prank(oldAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, oldAdmin));
        interopFeeManager.withdraw(l2ChainId, to, 0.6 ether);

        vm.prank(newAdmin);
        interopFeeManager.withdraw(l2ChainId, to, 0.6 ether);
        assertEq(to.balance, 1 ether);
        assertEq(interopFeeManager.chainBalance(l2ChainId), 0);
    }

    function testFuzz_execute_chargesLinearlyInUnits(uint32 _units, uint64 _feePerUnit) public {
        _setFee(_feePerUnit);
        uint256 fee = uint256(_feePerUnit) * _units;
        if (fee != 0) {
            _fund(fee);
        }

        _execute(_commitAndProve(_batchWithUnits(_units)));

        assertEq(interopFeeManager.chainBalance(l2ChainId), 0);
        assertEq(interopFeeManager.accruedFees(), fee);
    }

    function _batchWithUnits(uint256 _units) internal view returns (CommitBatchInfoZKsyncOS memory batch) {
        batch = newCommitBatchInfoZKsyncOS;
        // Executed without dependency interop roots, whose rolling hash is then zero.
        batch.dependencyRootsRollingHash = bytes32(0);
        batch.interopFeeUnits = _units;
    }

    /// @dev Commits `_batch` after genesis and proves it.
    function _commitAndProve(
        CommitBatchInfoZKsyncOS memory _batch
    ) internal returns (IExecutor.StoredBatchInfo memory stored) {
        stored = _commitOSBatchGetStored(genesisStoredBatchInfo, _batch);
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = stored;
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            batches,
            proofInput
        );
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, data);
    }

    function _execute(IExecutor.StoredBatchInfo memory _stored) internal {
        (uint256 from, uint256 to, bytes memory data) = _encodeExecute(_stored);
        vm.prank(validator);
        executor.executeBatchesSharedBridge(address(0), from, to, data);
    }

    /// @dev Execute data for one batch without priority operations.
    function _encodeExecute(
        IExecutor.StoredBatchInfo memory _stored
    ) internal pure returns (uint256 from, uint256 to, bytes memory data) {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _stored;
        return Utils.encodeExecuteBatchesData(batches, Utils.generatePriorityOps(1, 0));
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
}
