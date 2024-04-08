// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Utils} from "../Utils/Utils.sol";
import {ValidatorTimelock, IExecutor} from "contracts/state-transition/ValidatorTimelock.sol";
import {DummyStateTransitionManagerForValidatorTimelock} from "contracts/dev-contracts/test/DummyStateTransitionManagerForValidatorTimelock.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";

contract ValidatorTimelockTest is Test {
    /// @notice A new validator has been added.
    event ValidatorAdded(uint256 indexed _chainId, address _addedValidator);

    /// @notice A validator has been removed.
    event ValidatorRemoved(uint256 indexed _chainId, address _removedValidator);

    /// @notice Error for when an address is already a validator.
    error AddressAlreadyValidator(uint256 _chainId);

    /// @notice Error for when an address is not a validator.
    error ValidatorDoesNotExist(uint256 _chainId);

    ValidatorTimelock validator;
    DummyStateTransitionManagerForValidatorTimelock stateTransitionManager;

    address owner;
    address zkSync;
    address alice;
    address bob;
    address dan;
    uint256 chainId;
    uint256 eraChainId;
    uint256 lastBatchNumber;
    uint32 executionDelay;

    function setUp() public {
        owner = makeAddr("owner");
        zkSync = makeAddr("zkSync");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        dan = makeAddr("dan");
        chainId = 1;
        eraChainId = 9;
        lastBatchNumber = 123;
        executionDelay = 10;

        stateTransitionManager = new DummyStateTransitionManagerForValidatorTimelock(owner, zkSync);
        validator = new ValidatorTimelock(owner, executionDelay, eraChainId);
        vm.prank(owner);
        validator.setStateTransitionManager(IStateTransitionManager(address(stateTransitionManager)));
        vm.prank(owner);
        validator.addValidator(chainId, alice);
        vm.prank(owner);
        validator.addValidator(eraChainId, dan);
    }

    function test_addValidator() public {
        assert(validator.validators(chainId, bob) == false);

        vm.prank(owner);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(validator));
        emit ValidatorAdded(chainId, bob);
        validator.addValidator(chainId, bob);

        assert(validator.validators(chainId, bob) == true);
    }

    function test_removeValidator() public {
        vm.prank(owner);
        validator.addValidator(chainId, bob);
        assert(validator.validators(chainId, bob) == true);

        vm.prank(owner);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(validator));
        emit ValidatorRemoved(chainId, bob);
        validator.removeValidator(chainId, bob);

        assert(validator.validators(chainId, bob) == false);
    }

    function test_validatorCanMakeCall() public {
        // Setup Mock call to executor
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatchesSharedBridge.selector), "");

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(alice);
        validator.commitBatchesSharedBridge(chainId, storedBatch, batchesToCommit);
    }

    function test_setStateTransitionManager() public {
        assert(validator.stateTransitionManager() == IStateTransitionManager(address(stateTransitionManager)));

        DummyStateTransitionManagerForValidatorTimelock newManager = new DummyStateTransitionManagerForValidatorTimelock(
                bob,
                zkSync
            );
        vm.prank(owner);
        validator.setStateTransitionManager(IStateTransitionManager(address(newManager)));

        assert(validator.stateTransitionManager() == IStateTransitionManager(address(newManager)));
    }

    function test_setExecutionDelay() public {
        assert(validator.executionDelay() == executionDelay);

        vm.prank(owner);
        validator.setExecutionDelay(20);

        assert(validator.executionDelay() == 20);
    }

    function test_getCommittedBatchTimestampEmpty() public view {
        assert(validator.getCommittedBatchTimestamp(chainId, lastBatchNumber) == 0);
    }

    function test_getCommittedBatchTimestamp() public {
        uint64 batchNumber = 10;
        uint64 timestamp = 123456;

        vm.warp(timestamp);
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatches.selector), abi.encode(eraChainId));

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        batchToCommit.batchNumber = batchNumber;
        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(dan);
        validator.commitBatches(storedBatch, batchesToCommit);

        assert(validator.getCommittedBatchTimestamp(eraChainId, batchNumber) == timestamp);
    }

    function test_commitBatches() public {
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatches.selector), abi.encode(chainId));

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(dan);
        validator.commitBatches(storedBatch, batchesToCommit);
    }

    function test_revertBatches() public {
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.revertBatches.selector), abi.encode(lastBatchNumber));

        vm.prank(dan);
        validator.revertBatches(lastBatchNumber);
    }

    function test_revertBatchesSharedBridge() public {
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.revertBatches.selector), abi.encode(chainId));

        vm.prank(alice);
        validator.revertBatchesSharedBridge(chainId, lastBatchNumber);
    }

    function test_proveBatches() public {
        IExecutor.StoredBatchInfo memory prevBatch = Utils.createStoredBatchInfo();
        IExecutor.StoredBatchInfo memory batchToProve = Utils.createStoredBatchInfo();
        IExecutor.ProofInput memory proof = Utils.createProofInput();

        IExecutor.StoredBatchInfo[] memory batchesToProve = new IExecutor.StoredBatchInfo[](1);
        batchesToProve[0] = batchToProve;

        vm.mockCall(
            zkSync,
            abi.encodeWithSelector(IExecutor.proveBatches.selector),
            abi.encode(prevBatch, batchesToProve, proof)
        );
        vm.prank(dan);
        validator.proveBatches(prevBatch, batchesToProve, proof);
    }

    function test_proveBatchesSharedBridge() public {
        IExecutor.StoredBatchInfo memory prevBatch = Utils.createStoredBatchInfo();
        IExecutor.StoredBatchInfo memory batchToProve = Utils.createStoredBatchInfo();
        IExecutor.ProofInput memory proof = Utils.createProofInput();

        IExecutor.StoredBatchInfo[] memory batchesToProve = new IExecutor.StoredBatchInfo[](1);
        batchesToProve[0] = batchToProve;

        vm.mockCall(
            zkSync,
            abi.encodeWithSelector(IExecutor.proveBatches.selector),
            abi.encode(chainId, prevBatch, batchesToProve, proof)
        );
        vm.prank(alice);
        validator.proveBatchesSharedBridge(chainId, prevBatch, batchesToProve, proof);
    }

    function test_executeBatches() public {
        uint64 timestamp = 123456;
        uint64 batchNumber = 123;
        // Commit batches first to have the valid timestamp
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatches.selector), abi.encode(chainId));

        IExecutor.StoredBatchInfo memory storedBatch1 = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        batchToCommit.batchNumber = batchNumber;
        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(dan);
        vm.warp(timestamp);
        validator.commitBatches(storedBatch1, batchesToCommit);

        // Execute batches
        IExecutor.StoredBatchInfo memory storedBatch2 = Utils.createStoredBatchInfo();
        storedBatch2.batchNumber = batchNumber;
        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch2;

        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.proveBatches.selector), abi.encode(storedBatches));

        vm.prank(dan);
        vm.warp(timestamp + executionDelay + 1);
        validator.executeBatches(storedBatches);
    }

    function test_executeBatchesSharedBridge() public {
        uint64 timestamp = 123456;
        uint64 batchNumber = 123;
        // Commit batches first to have the valid timestamp
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatches.selector), abi.encode(chainId));

        IExecutor.StoredBatchInfo memory storedBatch1 = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        batchToCommit.batchNumber = batchNumber;
        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(alice);
        vm.warp(timestamp);
        validator.commitBatchesSharedBridge(chainId, storedBatch1, batchesToCommit);

        // Execute batches
        IExecutor.StoredBatchInfo memory storedBatch2 = Utils.createStoredBatchInfo();
        storedBatch2.batchNumber = batchNumber;
        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch2;

        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.proveBatches.selector), abi.encode(storedBatches));

        vm.prank(alice);
        vm.warp(timestamp + executionDelay + 1);
        validator.executeBatchesSharedBridge(chainId, storedBatches);
    }

    function test_RevertWhen_setExecutionDelayNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        validator.setExecutionDelay(20);
    }

    function test_RevertWhen_addValidatorNotAdmin() public {
        assert(validator.validators(chainId, bob) == false);

        vm.expectRevert("ValidatorTimelock: only chain admin");
        validator.addValidator(chainId, bob);

        assert(validator.validators(chainId, bob) == false);
    }

    function test_RevertWhen_removeValidatorNotAdmin() public {
        assert(validator.validators(chainId, alice) == true);

        vm.expectRevert("ValidatorTimelock: only chain admin");
        validator.removeValidator(chainId, alice);

        assert(validator.validators(chainId, alice) == true);
    }

    function test_RevertWhen_addValidatorAddressAlreadyValidator() public {
        assert(validator.validators(chainId, alice) == true);

        vm.prank(owner);
        vm.expectRevert(abi.encodePacked(AddressAlreadyValidator.selector, chainId));
        validator.addValidator(chainId, alice);
    }

    function test_RevertWhen_removeValidatorAddressNotValidator() public {
        assert(validator.validators(chainId, bob) == false);

        vm.prank(owner);
        vm.expectRevert(abi.encodePacked(ValidatorDoesNotExist.selector, chainId));
        validator.removeValidator(chainId, bob);
    }

    function test_RevertWhen_validatorCanMakeCallNotValidator() public {
        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(bob);
        vm.expectRevert(bytes("ValidatorTimelock: only validator"));
        validator.commitBatches(storedBatch, batchesToCommit);
    }

    function test_RevertWhen_setStateTransitionManagerNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        validator.setStateTransitionManager(IStateTransitionManager(address(stateTransitionManager)));
    }

    function test_RevertWhen_revertBatchesNotValidator() public {
        vm.expectRevert("ValidatorTimelock: only validator");
        validator.revertBatches(lastBatchNumber);
    }

    function test_RevertWhen_revertBatchesSharedBridgeNotValidator() public {
        vm.expectRevert("ValidatorTimelock: only validator");
        validator.revertBatchesSharedBridge(chainId, lastBatchNumber);
    }

    function test_RevertWhen_proveBatchesNotValidator() public {
        IExecutor.StoredBatchInfo memory prevBatch = Utils.createStoredBatchInfo();
        IExecutor.StoredBatchInfo memory batchToProve = Utils.createStoredBatchInfo();
        IExecutor.ProofInput memory proof = Utils.createProofInput();

        IExecutor.StoredBatchInfo[] memory batchesToProve = new IExecutor.StoredBatchInfo[](1);
        batchesToProve[0] = batchToProve;

        vm.expectRevert("ValidatorTimelock: only validator");
        validator.proveBatches(prevBatch, batchesToProve, proof);
    }

    function test_RevertWhen_proveBatchesSharedBridgeNotValidator() public {
        IExecutor.StoredBatchInfo memory prevBatch = Utils.createStoredBatchInfo();
        IExecutor.StoredBatchInfo memory batchToProve = Utils.createStoredBatchInfo();
        IExecutor.ProofInput memory proof = Utils.createProofInput();

        IExecutor.StoredBatchInfo[] memory batchesToProve = new IExecutor.StoredBatchInfo[](1);
        batchesToProve[0] = batchToProve;

        vm.prank(bob);
        vm.expectRevert("ValidatorTimelock: only validator");
        validator.proveBatchesSharedBridge(chainId, prevBatch, batchesToProve, proof);
    }

    function test_RevertWhen_executeBatchesNotValidator() public {
        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();

        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch;

        vm.prank(bob);
        vm.expectRevert("ValidatorTimelock: only validator");
        validator.executeBatches(storedBatches);
    }

    function test_RevertWhen_executeBatchesSharedBridgeNotValidator() public {
        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();

        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch;

        vm.prank(bob);
        vm.expectRevert("ValidatorTimelock: only validator");
        validator.executeBatchesSharedBridge(chainId, storedBatches);
    }

    function test_RevertWhen_executeBatchesTooEarly() public {
        uint64 timestamp = 123456;
        uint64 batchNumber = 123;
        // Prove batches first to have the valid timestamp
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatches.selector), abi.encode(chainId));

        IExecutor.StoredBatchInfo memory storedBatch1 = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        batchToCommit.batchNumber = batchNumber;
        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(dan);
        vm.warp(timestamp);
        validator.commitBatches(storedBatch1, batchesToCommit);

        // Execute batches
        IExecutor.StoredBatchInfo memory storedBatch2 = Utils.createStoredBatchInfo();
        storedBatch2.batchNumber = batchNumber;
        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch2;

        vm.prank(dan);
        vm.warp(timestamp + executionDelay - 1);
        vm.expectRevert(bytes("5c"));
        validator.executeBatches(storedBatches);
    }

    function test_RevertWhen_executeBatchesSharedBridgeTooEarly() public {
        uint64 timestamp = 123456;
        uint64 batchNumber = 123;
        // Prove batches first to have the valid timestamp
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatches.selector), abi.encode(chainId));

        IExecutor.StoredBatchInfo memory storedBatch1 = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        batchToCommit.batchNumber = batchNumber;
        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(alice);
        vm.warp(timestamp);
        validator.commitBatchesSharedBridge(chainId, storedBatch1, batchesToCommit);

        // Execute batches
        IExecutor.StoredBatchInfo memory storedBatch2 = Utils.createStoredBatchInfo();
        storedBatch2.batchNumber = batchNumber;
        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch2;

        vm.prank(alice);
        vm.warp(timestamp + executionDelay - 1);
        vm.expectRevert(bytes("5c"));
        validator.executeBatchesSharedBridge(chainId, storedBatches);
    }
}
