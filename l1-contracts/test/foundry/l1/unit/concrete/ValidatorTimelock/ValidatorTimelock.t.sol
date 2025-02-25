// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Utils} from "../Utils/Utils.sol";
import {ValidatorTimelock, IExecutor} from "contracts/state-transition/ValidatorTimelock.sol";
import {DummyChainTypeManagerForValidatorTimelock} from "contracts/dev-contracts/test/DummyChainTypeManagerForValidatorTimelock.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Unauthorized, TimeNotReached} from "contracts/common/L1ContractErrors.sol";

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
    DummyChainTypeManagerForValidatorTimelock chainTypeManager;

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

        chainTypeManager = new DummyChainTypeManagerForValidatorTimelock(owner, zkSync);
        validator = new ValidatorTimelock(owner, executionDelay);
        vm.prank(owner);
        validator.setChainTypeManager(IChainTypeManager(address(chainTypeManager)));
        vm.prank(owner);
        validator.addValidator(chainId, alice);
        vm.prank(owner);
        validator.addValidator(eraChainId, dan);
    }

    function test_SuccessfulConstruction() public {
        ValidatorTimelock validator = new ValidatorTimelock(owner, executionDelay);

        assertEq(validator.owner(), owner);
        assertEq(validator.executionDelay(), executionDelay);
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
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            storedBatch,
            batchesToCommit
        );
        validator.commitBatchesSharedBridge(chainId, commitBatchFrom, commitBatchTo, commitData);
    }

    function test_setChainTypeManager() public {
        assert(validator.chainTypeManager() == IChainTypeManager(address(chainTypeManager)));

        DummyChainTypeManagerForValidatorTimelock newManager = new DummyChainTypeManagerForValidatorTimelock(
            bob,
            zkSync
        );
        vm.prank(owner);
        validator.setChainTypeManager(IChainTypeManager(address(newManager)));

        assert(validator.chainTypeManager() == IChainTypeManager(address(newManager)));
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
        vm.mockCall(
            zkSync,
            abi.encodeWithSelector(IExecutor.commitBatchesSharedBridge.selector),
            abi.encode(eraChainId)
        );

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        batchToCommit.batchNumber = batchNumber;
        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(alice);
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            storedBatch,
            batchesToCommit
        );
        validator.commitBatchesSharedBridge(chainId, commitBatchFrom, commitBatchTo, commitData);

        assert(validator.getCommittedBatchTimestamp(chainId, batchNumber) == timestamp);
    }

    function test_commitBatches() public {
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatchesSharedBridge.selector), abi.encode(chainId));

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(alice);
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            storedBatch,
            batchesToCommit
        );
        validator.commitBatchesSharedBridge(chainId, commitBatchFrom, commitBatchTo, commitData);
    }

    function test_revertBatchesSharedBridge() public {
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.revertBatchesSharedBridge.selector), abi.encode(chainId));

        vm.prank(alice);
        validator.revertBatchesSharedBridge(chainId, lastBatchNumber);
    }

    function test_proveBatchesSharedBridge() public {
        IExecutor.StoredBatchInfo memory prevBatch = Utils.createStoredBatchInfo();
        IExecutor.StoredBatchInfo memory batchToProve = Utils.createStoredBatchInfo();
        uint256[] memory proof = new uint256[](0);

        IExecutor.StoredBatchInfo[] memory batchesToProve = new IExecutor.StoredBatchInfo[](1);
        batchesToProve[0] = batchToProve;

        vm.mockCall(
            zkSync,
            abi.encodeWithSelector(IExecutor.proveBatchesSharedBridge.selector),
            abi.encode(chainId, prevBatch, batchesToProve, proof)
        );
        vm.prank(alice);
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            prevBatch,
            batchesToProve,
            proof
        );
        validator.proveBatchesSharedBridge(chainId, proveBatchFrom, proveBatchTo, proveData);
    }

    function test_executeBatchesSharedBridge() public {
        uint64 timestamp = 123456;
        uint64 batchNumber = 123;
        // Commit batches first to have the valid timestamp
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatchesSharedBridge.selector), abi.encode(chainId));

        IExecutor.StoredBatchInfo memory storedBatch1 = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        batchToCommit.batchNumber = batchNumber;
        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(alice);
        vm.warp(timestamp);
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            storedBatch1,
            batchesToCommit
        );
        validator.commitBatchesSharedBridge(chainId, commitBatchFrom, commitBatchTo, commitData);

        // Execute batches
        IExecutor.StoredBatchInfo memory storedBatch2 = Utils.createStoredBatchInfo();
        storedBatch2.batchNumber = batchNumber;
        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch2;

        vm.mockCall(
            zkSync,
            abi.encodeWithSelector(IExecutor.proveBatchesSharedBridge.selector),
            abi.encode(storedBatches)
        );

        vm.prank(alice);
        vm.warp(timestamp + executionDelay + 1);
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatches,
            Utils.emptyData()
        );
        validator.executeBatchesSharedBridge(chainId, executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_setExecutionDelayNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        validator.setExecutionDelay(20);
    }

    function test_RevertWhen_addValidatorNotAdmin() public {
        assert(validator.validators(chainId, bob) == false);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        validator.addValidator(chainId, bob);

        assert(validator.validators(chainId, bob) == false);
    }

    function test_RevertWhen_removeValidatorNotAdmin() public {
        assert(validator.validators(chainId, alice) == true);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
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
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, bob));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            storedBatch,
            batchesToCommit
        );
        validator.commitBatchesSharedBridge(chainId, commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_setChainTypeManagerNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        validator.setChainTypeManager(IChainTypeManager(address(chainTypeManager)));
    }

    function test_RevertWhen_revertBatchesNotValidator() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        validator.revertBatchesSharedBridge(uint256(0), lastBatchNumber);
    }

    function test_RevertWhen_revertBatchesSharedBridgeNotValidator() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        validator.revertBatchesSharedBridge(chainId, lastBatchNumber);
    }

    function test_RevertWhen_proveBatchesSharedBridgeNotValidator() public {
        IExecutor.StoredBatchInfo memory prevBatch = Utils.createStoredBatchInfo();
        IExecutor.StoredBatchInfo memory batchToProve = Utils.createStoredBatchInfo();
        uint256[] memory proof = new uint256[](0);

        IExecutor.StoredBatchInfo[] memory batchesToProve = new IExecutor.StoredBatchInfo[](1);
        batchesToProve[0] = batchToProve;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, bob));
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            prevBatch,
            batchesToProve,
            proof
        );
        validator.proveBatchesSharedBridge(chainId, proveBatchFrom, proveBatchTo, proveData);
    }

    function test_RevertWhen_executeBatchesSharedBridgeNotValidator() public {
        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();

        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, bob));
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatches,
            Utils.emptyData()
        );
        validator.executeBatchesSharedBridge(chainId, executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_executeBatchesSharedBridgeTooEarly() public {
        uint64 timestamp = 123456;
        uint64 batchNumber = 123;
        // Prove batches first to have the valid timestamp
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatchesSharedBridge.selector), abi.encode(chainId));

        IExecutor.StoredBatchInfo memory storedBatch1 = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        batchToCommit.batchNumber = batchNumber;
        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(alice);
        vm.warp(timestamp);
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            storedBatch1,
            batchesToCommit
        );
        validator.commitBatchesSharedBridge(chainId, commitBatchFrom, commitBatchTo, commitData);

        // Execute batches
        IExecutor.StoredBatchInfo memory storedBatch2 = Utils.createStoredBatchInfo();
        storedBatch2.batchNumber = batchNumber;
        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch2;

        vm.prank(alice);
        vm.warp(timestamp + executionDelay - 1);
        vm.expectRevert(
            abi.encodeWithSelector(TimeNotReached.selector, timestamp + executionDelay, timestamp + executionDelay - 1)
        );
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatches,
            Utils.emptyData()
        );
        validator.executeBatchesSharedBridge(chainId, executeBatchFrom, executeBatchTo, executeData);
    }
}
