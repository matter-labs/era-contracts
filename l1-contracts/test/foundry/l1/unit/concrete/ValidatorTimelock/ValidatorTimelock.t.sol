// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Utils} from "../Utils/Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {DummyChainTypeManagerForValidatorTimelock} from "contracts/dev-contracts/test/DummyChainTypeManagerForValidatorTimelock.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Unauthorized, TimeNotReached, RoleAccessDenied} from "contracts/common/L1ContractErrors.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {AccessControlEnumerablePerChainAddressUpgradeable} from "contracts/state-transition/AccessControlEnumerablePerChainAddressUpgradeable.sol";

contract ValidatorTimelockTest is Test {
    /// @notice A new validator has been added.
    event ValidatorAdded(uint256 indexed _chainId, address _addedValidator);

    /// @notice A validator has been removed.
    event ValidatorRemoved(uint256 indexed _chainId, address _removedValidator);

    /// @notice Error for when an address is already a validator.
    error AddressAlreadyValidator(uint256 _chainId);

    /// @notice Error for when an address is not a validator.
    error ValidatorDoesNotExist(uint256 _chainId);

    /// @notice The default admin role identifier.
    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);

    ValidatorTimelock validator;
    DummyChainTypeManagerForValidatorTimelock chainTypeManager;
    DummyBridgehub dummyBridgehub;

    address owner;
    address zkSync;
    address alice;
    address bob;
    address dan;
    uint256 chainId;
    uint256 eraChainId;
    uint256 lastBatchNumber;
    uint32 executionDelay;

    bytes32 precommitterRole;
    bytes32 committerRole;
    bytes32 reverterRole;
    bytes32 proverRole;
    bytes32 executorRole;
    bytes32 precommitterAdminRole;
    bytes32 committerAdminRole;
    bytes32 reverterAdminRole;
    bytes32 proverAdminRole;
    bytes32 executorAdminRole;

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

        dummyBridgehub = new DummyBridgehub();

        chainTypeManager = new DummyChainTypeManagerForValidatorTimelock(owner, zkSync);

        vm.mockCall(zkSync, abi.encodeCall(IGetters.getAdmin, ()), abi.encode(owner));
        vm.mockCall(zkSync, abi.encodeCall(IGetters.getChainId, ()), abi.encode(chainId));
        dummyBridgehub.setZKChain(chainId, zkSync);

        validator = ValidatorTimelock(_deployValidatorTimelock(owner, executionDelay));
        vm.prank(owner);
        validator.addValidatorForChainId(chainId, alice);
        vm.prank(owner);
        validator.addValidatorForChainId(eraChainId, dan);

        precommitterRole = validator.PRECOMMITTER_ROLE();
        committerRole = validator.COMMITTER_ROLE();
        reverterRole = validator.REVERTER_ROLE();
        proverRole = validator.PROVER_ROLE();
        executorRole = validator.EXECUTOR_ROLE();
        precommitterAdminRole = validator.OPTIONAL_PRECOMMITTER_ADMIN_ROLE();
        committerAdminRole = validator.OPTIONAL_COMMITTER_ADMIN_ROLE();
        reverterAdminRole = validator.OPTIONAL_REVERTER_ADMIN_ROLE();
        proverAdminRole = validator.OPTIONAL_PROVER_ADMIN_ROLE();
        executorAdminRole = validator.OPTIONAL_EXECUTOR_ADMIN_ROLE();
    }

    function _deployValidatorTimelock(address _initialOwner, uint32 _initialExecutionDelay) internal returns (address) {
        ProxyAdmin admin = new ProxyAdmin();
        ValidatorTimelock timelockImplementation = new ValidatorTimelock(address(dummyBridgehub));
        return
            address(
                new TransparentUpgradeableProxy(
                    address(timelockImplementation),
                    address(admin),
                    abi.encodeCall(ValidatorTimelock.initialize, (_initialOwner, _initialExecutionDelay))
                )
            );
    }

    function test_SuccessfulConstruction() public {
        ValidatorTimelock validator = ValidatorTimelock(_deployValidatorTimelock(owner, executionDelay));
        assertEq(validator.owner(), owner);
        assertEq(validator.executionDelay(), executionDelay);
    }

    function _assertAllRoles(uint256 _chainId, address _addr, bool _expected) internal {
        require(validator.hasRoleForChainId(_chainId, validator.PRECOMMITTER_ROLE(), _addr) == _expected);
        require(validator.hasRoleForChainId(_chainId, validator.COMMITTER_ROLE(), _addr) == _expected);
        require(validator.hasRoleForChainId(_chainId, validator.REVERTER_ROLE(), _addr) == _expected);
        require(validator.hasRoleForChainId(_chainId, validator.PROVER_ROLE(), _addr) == _expected);
        require(validator.hasRoleForChainId(_chainId, validator.EXECUTOR_ROLE(), _addr) == _expected);
    }

    function test_addValidatorForChainId() public {
        _assertAllRoles(chainId, bob, false);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleGranted(zkSync, precommitterRole, bob);
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleGranted(zkSync, committerRole, bob);
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleGranted(zkSync, reverterRole, bob);
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleGranted(zkSync, proverRole, bob);
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleGranted(zkSync, executorRole, bob);
        validator.addValidatorForChainId(chainId, bob);

        _assertAllRoles(chainId, bob, true);
    }

    function test_removeValidatorForChainId() public {
        vm.prank(owner);
        validator.addValidatorForChainId(chainId, bob);
        _assertAllRoles(chainId, bob, true);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleRevoked(zkSync, precommitterRole, bob);
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleRevoked(zkSync, committerRole, bob);
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleRevoked(zkSync, reverterRole, bob);
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleRevoked(zkSync, proverRole, bob);
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleRevoked(zkSync, executorRole, bob);
        validator.removeValidatorForChainId(chainId, bob);

        _assertAllRoles(chainId, bob, false);
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
        validator.commitBatchesSharedBridge(zkSync, commitBatchFrom, commitBatchTo, commitData);
    }

    function test_setExecutionDelay() public {
        assert(validator.executionDelay() == executionDelay);

        vm.prank(owner);
        validator.setExecutionDelay(20);

        assert(validator.executionDelay() == 20);
    }

    function test_getCommittedBatchTimestampEmpty() public view {
        assert(validator.getCommittedBatchTimestamp(zkSync, lastBatchNumber) == 0);
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
        validator.commitBatchesSharedBridge(zkSync, commitBatchFrom, commitBatchTo, commitData);

        assert(validator.getCommittedBatchTimestamp(zkSync, batchNumber) == timestamp);
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
        validator.commitBatchesSharedBridge(zkSync, commitBatchFrom, commitBatchTo, commitData);
    }

    function test_revertBatchesSharedBridge() public {
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.revertBatchesSharedBridge.selector), abi.encode(chainId));

        vm.prank(alice);
        validator.revertBatchesSharedBridge(zkSync, lastBatchNumber);
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
            abi.encode(zkSync, prevBatch, batchesToProve, proof)
        );
        vm.prank(alice);
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            prevBatch,
            batchesToProve,
            proof
        );
        validator.proveBatchesSharedBridge(zkSync, proveBatchFrom, proveBatchTo, proveData);
    }

    function test_executeBatchesSharedBridge() public {
        uint64 timestamp = 123456;
        uint64 batchNumber = 123;
        // Commit batches first to have the valid timestamp
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatchesSharedBridge.selector), abi.encode(zkSync));

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
        validator.commitBatchesSharedBridge(zkSync, commitBatchFrom, commitBatchTo, commitData);

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
        validator.executeBatchesSharedBridge(zkSync, executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_setExecutionDelayNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        validator.setExecutionDelay(20);
    }

    function test_RevertWhen_addValidatorNotAdmin() public {
        _assertAllRoles(chainId, bob, false);

        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, DEFAULT_ADMIN_ROLE, address(this)));
        validator.addValidatorForChainId(chainId, bob);

        _assertAllRoles(chainId, bob, false);
    }

    function test_RevertWhen_removeValidatorNotAdmin() public {
        _assertAllRoles(chainId, alice, true);

        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, DEFAULT_ADMIN_ROLE, address(this)));
        validator.removeValidatorForChainId(chainId, alice);

        _assertAllRoles(chainId, alice, true);
    }

    function test_RevertWhen_validatorCanMakeCallNotValidator() public {
        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, committerRole, bob));
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            storedBatch,
            batchesToCommit
        );
        validator.commitBatchesSharedBridge(zkSync, commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_revertBatchesNotValidator() public {
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, address(0), reverterRole, address(this)));
        validator.revertBatchesSharedBridge(address(0), lastBatchNumber);
    }

    function test_RevertWhen_revertBatchesSharedBridgeNotValidator() public {
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, reverterRole, address(this)));
        validator.revertBatchesSharedBridge(zkSync, lastBatchNumber);
    }

    function test_RevertWhen_proveBatchesSharedBridgeNotValidator() public {
        IExecutor.StoredBatchInfo memory prevBatch = Utils.createStoredBatchInfo();
        IExecutor.StoredBatchInfo memory batchToProve = Utils.createStoredBatchInfo();
        uint256[] memory proof = new uint256[](0);

        IExecutor.StoredBatchInfo[] memory batchesToProve = new IExecutor.StoredBatchInfo[](1);
        batchesToProve[0] = batchToProve;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, proverRole, bob));
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            prevBatch,
            batchesToProve,
            proof
        );
        validator.proveBatchesSharedBridge(zkSync, proveBatchFrom, proveBatchTo, proveData);
    }

    function test_RevertWhen_executeBatchesSharedBridgeNotValidator() public {
        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();

        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, executorRole, bob));
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatches,
            Utils.emptyData()
        );
        validator.executeBatchesSharedBridge(zkSync, executeBatchFrom, executeBatchTo, executeData);
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
        validator.commitBatchesSharedBridge(zkSync, commitBatchFrom, commitBatchTo, commitData);

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
        validator.executeBatchesSharedBridge(zkSync, executeBatchFrom, executeBatchTo, executeData);
    }
}
