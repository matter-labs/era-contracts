pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {DummyExecutor} from "contracts/dev-contracts/test/DummyExecutor.sol";
import {DummyStateTransitionManager} from "contracts/dev-contracts/test/DummyStateTransitionManager.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {Utils, DEFAULT_L2_LOGS_TREE_ROOT_HASH} from "test/foundry/unit/concrete/Utils/Utils.sol";

contract ValidatorTest is Test {
    ValidatorTimelock validatorTimelock;
    DummyExecutor dummyExecutor;
    DummyStateTransitionManager dummyStateTransitionManager;
    IExecutor.ProofInput proofInput;

    uint256 chainId = 270;
    address owner;
    address chainAdmin;
    address newValidator;

    function getMockCommitBatchInfo(uint64 batchNumber) public returns (IExecutor.CommitBatchInfo[] memory) {
        bytes memory l2Logs = Utils.encodePacked(Utils.createSystemLogs());
        IExecutor.CommitBatchInfo[] memory commitBatches = new IExecutor.CommitBatchInfo[](1);
        commitBatches[0] = IExecutor.CommitBatchInfo({
            batchNumber: batchNumber,
            timestamp: 0,
            indexRepeatedStorageChanges: 0,
            newStateRoot: Utils.randomBytes32("newStateRoot"),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            bootloaderHeapInitialContentsHash: Utils.randomBytes32("bootloaderHeapInitialContentsHash"),
            eventsQueueStateHash: Utils.randomBytes32("eventsQueueStateHash"),
            systemLogs: l2Logs,
            pubdataCommitments: bytes("")
        });

        return commitBatches;
    }

    function getMockStoredBatchInfo(
        uint64 batchNumber,
        uint64 timestamp
    ) public returns (IExecutor.StoredBatchInfo[] memory) {
        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = IExecutor.StoredBatchInfo({
            batchNumber: batchNumber,
            batchHash: bytes32(""),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            timestamp: 0,
            commitment: bytes32("")
        });
        return storedBatches;
    }

    function setUp() public {
        owner = msg.sender;
        newValidator = makeAddr("random address");

        vm.startBroadcast(owner);
        dummyExecutor = new DummyExecutor();
        vm.stopBroadcast();

        vm.startBroadcast(owner);
        dummyStateTransitionManager = new DummyStateTransitionManager();
        vm.stopBroadcast();

        validatorTimelock = new ValidatorTimelock(owner, 0, chainId);

        vm.startBroadcast(owner);
        validatorTimelock.setStateTransitionManager(dummyStateTransitionManager);
        vm.stopBroadcast();

        dummyStateTransitionManager.setHyperchain(chainId, address(dummyExecutor));

        uint256[] memory recursiveAggregationInput;
        uint256[] memory serializedProof;
        proofInput = IExecutor.ProofInput(recursiveAggregationInput, serializedProof);
        chainAdmin = dummyStateTransitionManager.getChainAdmin(chainId);
    }

    function test_checkDeployment() public {
        assertEq(validatorTimelock.owner(), owner);
        assertEq(validatorTimelock.executionDelay(), 0);
        assertFalse(validatorTimelock.validators(chainId, 0x0000000000000000000000000000000000000000));
        assertEq(address(validatorTimelock.stateTransitionManager()), address(dummyStateTransitionManager));
        assertEq(dummyStateTransitionManager.getHyperchain(chainId), address(dummyExecutor));
        assertEq(dummyStateTransitionManager.getChainAdmin(chainId), owner);
        assertEq(dummyExecutor.getAdmin(), owner);
    }

    function test_nonValidatorCommitsBatches() public {
        IExecutor.StoredBatchInfo[] memory storedBatch = getMockStoredBatchInfo(0, 0);

        // vm.expectRevert("ValidatorTimelock: only validator");

        vm.startBroadcast(makeAddr("random address"));
        validatorTimelock.commitBatches(storedBatch[0], getMockCommitBatchInfo(1));
        vm.stopBroadcast();
    }

    function test_nonValidatorProvesBatches() public {
        IExecutor.StoredBatchInfo[] memory storedBatch = getMockStoredBatchInfo(0, 0);
        IExecutor.StoredBatchInfo[] memory storedBatch1 = getMockStoredBatchInfo(1, 0);

        vm.startBroadcast(makeAddr("random address"));
        vm.expectRevert("ValidatorTimelock: only validator");
        validatorTimelock.proveBatches(storedBatch[0], storedBatch1, proofInput);
        vm.stopBroadcast();
    }

    function test_nonValidatorRevertsBatches() public {
        vm.startBroadcast(makeAddr("random address"));
        vm.expectRevert("ValidatorTimelock: only validator");
        validatorTimelock.revertBatches(1);
        vm.stopBroadcast();
    }

    function test_nonValidatorExecutesBatches() public {
        vm.startBroadcast(makeAddr("random address"));
        vm.expectRevert("ValidatorTimelock: only validator");
        validatorTimelock.executeBatches(getMockStoredBatchInfo(1, 0));
        vm.stopBroadcast();
    }

    function test_nonGovernorSetsValidator() public {
        vm.startBroadcast(makeAddr("random address"));
        vm.expectRevert("ValidatorTimelock: only chain admin");
        validatorTimelock.addValidator(chainId, makeAddr("random address"));
        vm.stopBroadcast();
    }

    function test_nonOwnerSetsExecutionDelay() public {
        vm.startBroadcast(makeAddr("random address"));
        vm.expectRevert("Ownable: caller is not the owner");
        validatorTimelock.setExecutionDelay(1000);
        vm.stopBroadcast();
    }

    function test_setValidator() public {
        vm.startBroadcast(chainAdmin);
        validatorTimelock.addValidator(chainId, newValidator);
        vm.stopBroadcast();

        assertTrue(validatorTimelock.validators(chainId, newValidator));
    }

    function test_setExecutionDelay() public {
        vm.startBroadcast(chainAdmin);
        validatorTimelock.setExecutionDelay(1000);
        vm.stopBroadcast();

        assertEq(validatorTimelock.executionDelay(), 1000);
    }

    function test_commitBatches() public {
        IExecutor.StoredBatchInfo[] memory storedBatch = getMockStoredBatchInfo(0, 0);

        vm.startBroadcast(chainAdmin);
        validatorTimelock.addValidator(chainId, newValidator);
        vm.stopBroadcast();

        vm.startBroadcast(newValidator);
        validatorTimelock.commitBatchesSharedBridge(chainId, storedBatch[0], getMockCommitBatchInfo(1));
        vm.stopBroadcast();

        assertEq(dummyExecutor.getTotalBatchesCommitted(), 1);
    }

    function test_proveBatches() public {
        IExecutor.StoredBatchInfo[] memory storedBatch = getMockStoredBatchInfo(0, 0);
        IExecutor.StoredBatchInfo[] memory storedBatch1 = getMockStoredBatchInfo(1, 1);

        vm.startBroadcast(chainAdmin);
        validatorTimelock.addValidator(chainId, newValidator);
        vm.stopBroadcast();

        vm.startBroadcast(newValidator);
        validatorTimelock.commitBatchesSharedBridge(chainId, storedBatch[0], getMockCommitBatchInfo(1));
        validatorTimelock.proveBatchesSharedBridge(chainId, storedBatch[0], storedBatch1, proofInput);
        vm.stopBroadcast();

        assertEq(dummyExecutor.getTotalBatchesVerified(), 1);
    }

    function test_executeBeforeDelay() public {
        vm.startBroadcast(chainAdmin);
        validatorTimelock.setExecutionDelay(1000);
        validatorTimelock.addValidator(chainId, newValidator);
        vm.stopBroadcast();

        vm.startBroadcast(newValidator);
        vm.expectRevert(abi.encodePacked("5c"));
        validatorTimelock.executeBatchesSharedBridge(chainId, getMockStoredBatchInfo(1, 0));
        vm.stopBroadcast();
    }

    function test_revertBatches() public {
        IExecutor.StoredBatchInfo[] memory storedBatch = getMockStoredBatchInfo(0, 0);

        vm.startBroadcast(chainAdmin);
        validatorTimelock.addValidator(chainId, newValidator);
        vm.stopBroadcast();

        vm.startBroadcast(newValidator);
        validatorTimelock.commitBatchesSharedBridge(chainId, storedBatch[0], getMockCommitBatchInfo(1));
        validatorTimelock.revertBatchesSharedBridge(chainId, 0);
        vm.stopBroadcast();

        assertEq(dummyExecutor.getTotalBatchesCommitted(), 0);
        assertEq(dummyExecutor.getTotalBatchesVerified(), 0);
    }

    function test_overwriteTimestamp() public {
        IExecutor.StoredBatchInfo[] memory storedBatch = getMockStoredBatchInfo(0, 0);
        IExecutor.StoredBatchInfo[] memory storedBatch1 = getMockStoredBatchInfo(1, 0);

        vm.startBroadcast(chainAdmin);
        validatorTimelock.addValidator(chainId, newValidator);
        vm.stopBroadcast();

        vm.startBroadcast(newValidator);
        validatorTimelock.commitBatchesSharedBridge(chainId, storedBatch[0], getMockCommitBatchInfo(1));
        validatorTimelock.revertBatchesSharedBridge(chainId, 0);
        uint256 revertedBatchesTimestamp = validatorTimelock.getCommittedBatchTimestamp(chainId, 1);
        validatorTimelock.commitBatchesSharedBridge(chainId, storedBatch[0], getMockCommitBatchInfo(1));
        validatorTimelock.proveBatchesSharedBridge(chainId, storedBatch[0], storedBatch1, proofInput);
        uint256 newBatchesTimestamp = validatorTimelock.getCommittedBatchTimestamp(chainId, 1);
        vm.stopBroadcast();

        assertEq(revertedBatchesTimestamp, newBatchesTimestamp);
    }

    function test_executeAfterDelay() public {
        IExecutor.StoredBatchInfo[] memory storedBatch = getMockStoredBatchInfo(0, 0);
        IExecutor.StoredBatchInfo[] memory storedBatch1 = getMockStoredBatchInfo(1, 1);

        vm.startBroadcast(chainAdmin);
        validatorTimelock.addValidator(chainId, newValidator);
        validatorTimelock.setExecutionDelay(10);
        vm.stopBroadcast();

        vm.startBroadcast(newValidator);
        validatorTimelock.commitBatchesSharedBridge(chainId, storedBatch[0], getMockCommitBatchInfo(1));
        validatorTimelock.proveBatchesSharedBridge(chainId, storedBatch[0], storedBatch1, proofInput);
        vm.warp(11);
        validatorTimelock.executeBatchesSharedBridge(chainId, getMockStoredBatchInfo(1, 0));
        vm.stopBroadcast();

        assertEq(dummyExecutor.getTotalBatchesExecuted(), 1);
    }

    function test_commitWrongBatchNumber() public {
        IExecutor.StoredBatchInfo[] memory storedBatch = getMockStoredBatchInfo(1, 0);

        vm.startBroadcast(chainAdmin);
        validatorTimelock.addValidator(chainId, newValidator);
        vm.stopBroadcast();

        //vm.expectRevert("DummyExecutor: Invalid last committed batch number");

        vm.startBroadcast(newValidator);
        validatorTimelock.commitBatchesSharedBridge(chainId, storedBatch[0], getMockCommitBatchInfo(1));
        vm.stopBroadcast();
    }

    function test_proveWrongBatchNumber() public {
        IExecutor.StoredBatchInfo[] memory storedBatch = getMockStoredBatchInfo(0, 0);
        IExecutor.StoredBatchInfo[] memory storedBatch1 = getMockStoredBatchInfo(2, 1);

        vm.startBroadcast(chainAdmin);
        validatorTimelock.addValidator(chainId, newValidator);
        vm.stopBroadcast();

        //vm.expectRevert("DummyExecutor 1: Can't prove batch out of order");

        vm.startBroadcast(newValidator);
        validatorTimelock.commitBatchesSharedBridge(chainId, storedBatch[0], getMockCommitBatchInfo(1));
        validatorTimelock.proveBatchesSharedBridge(chainId, storedBatch[0], storedBatch1, proofInput);
        vm.stopBroadcast();
    }

    function test_executeMoreThenProved() public {
        vm.startBroadcast(chainAdmin);
        validatorTimelock.addValidator(chainId, newValidator);
        vm.stopBroadcast();

        vm.expectRevert("DummyExecutor 2: Can't execute batches more than committed and proven currently");

        vm.startBroadcast(newValidator);
        validatorTimelock.executeBatchesSharedBridge(chainId, getMockStoredBatchInfo(1, 0));
        vm.stopBroadcast();
    }
}
