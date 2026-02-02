// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Utils} from "../Utils/Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {DummyChainTypeManagerForValidatorTimelock} from "contracts/dev-contracts/test/DummyChainTypeManagerForValidatorTimelock.sol";

import {ActivatePriorityModeNotImplementedInValidatorContract, RoleAccessDenied, TimeNotReached, NotAZKChain} from "contracts/common/L1ContractErrors.sol";
import {IValidatorTimelock} from "contracts/state-transition/IValidatorTimelock.sol";
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

    function test_revertWhen_activatePriorityMode() public {
        vm.expectRevert(ActivatePriorityModeNotImplementedInValidatorContract.selector);
        validator.activatePriorityMode();
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

    function test_addValidatorRoles_PartialRoles() public {
        // Add only precommitter and committer roles
        IValidatorTimelock.ValidatorRotationParams memory params = IValidatorTimelock.ValidatorRotationParams({
            rotatePrecommitterRole: true,
            rotateCommitterRole: true,
            rotateReverterRole: false,
            rotateProverRole: false,
            rotateExecutorRole: false
        });

        // Bob should not have any roles initially
        assertFalse(validator.hasRoleForChainId(chainId, precommitterRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, committerRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, reverterRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, proverRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, executorRole, bob));

        vm.prank(owner);
        validator.addValidatorRoles(zkSync, bob, params);

        // Only precommitter and committer roles should be granted
        assertTrue(validator.hasRoleForChainId(chainId, precommitterRole, bob));
        assertTrue(validator.hasRoleForChainId(chainId, committerRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, reverterRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, proverRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, executorRole, bob));
    }

    function test_removeValidatorRoles_PartialRoles() public {
        // First add all roles
        vm.prank(owner);
        validator.addValidatorForChainId(chainId, bob);
        _assertAllRoles(chainId, bob, true);

        // Remove only reverter and prover roles
        IValidatorTimelock.ValidatorRotationParams memory params = IValidatorTimelock.ValidatorRotationParams({
            rotatePrecommitterRole: false,
            rotateCommitterRole: false,
            rotateReverterRole: true,
            rotateProverRole: true,
            rotateExecutorRole: false
        });

        vm.prank(owner);
        validator.removeValidatorRoles(zkSync, bob, params);

        // Precommitter, committer, and executor should still be present
        assertTrue(validator.hasRoleForChainId(chainId, precommitterRole, bob));
        assertTrue(validator.hasRoleForChainId(chainId, committerRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, reverterRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, proverRole, bob));
        assertTrue(validator.hasRoleForChainId(chainId, executorRole, bob));
    }

    function test_addValidatorRoles_OnlyExecutor() public {
        IValidatorTimelock.ValidatorRotationParams memory params = IValidatorTimelock.ValidatorRotationParams({
            rotatePrecommitterRole: false,
            rotateCommitterRole: false,
            rotateReverterRole: false,
            rotateProverRole: false,
            rotateExecutorRole: true
        });

        vm.prank(owner);
        validator.addValidatorRoles(zkSync, bob, params);

        assertFalse(validator.hasRoleForChainId(chainId, precommitterRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, committerRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, reverterRole, bob));
        assertFalse(validator.hasRoleForChainId(chainId, proverRole, bob));
        assertTrue(validator.hasRoleForChainId(chainId, executorRole, bob));
    }

    function test_precommitSharedBridge() public {
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.precommitSharedBridge.selector), "");

        vm.prank(alice);
        validator.precommitSharedBridge(zkSync, 1, "");
    }

    function test_RevertWhen_precommitSharedBridgeNotValidator() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, precommitterRole, bob));
        validator.precommitSharedBridge(zkSync, 1, "");
    }

    function test_RevertWhen_addValidatorRolesNotChain() public {
        // Create a fake chain address that has getChainId() and getAdmin() mocked
        // but the bridgehub.getZKChain returns a different address
        address fakeChain = makeAddr("fakeChain");
        uint256 fakeChainId = 999;

        vm.mockCall(fakeChain, abi.encodeCall(IGetters.getChainId, ()), abi.encode(fakeChainId));
        vm.mockCall(fakeChain, abi.encodeCall(IGetters.getAdmin, ()), abi.encode(owner));
        // Make bridgehub return a different address for this chain ID (simulating NotAZKChain)
        dummyBridgehub.setZKChain(fakeChainId, zkSync); // zkSync != fakeChain

        IValidatorTimelock.ValidatorRotationParams memory params = IValidatorTimelock.ValidatorRotationParams({
            rotatePrecommitterRole: true,
            rotateCommitterRole: false,
            rotateReverterRole: false,
            rotateProverRole: false,
            rotateExecutorRole: false
        });

        vm.expectRevert(abi.encodeWithSelector(NotAZKChain.selector, fakeChain));
        validator.addValidatorRoles(fakeChain, bob, params);
    }

    function test_executeBatchesSharedBridge_ZeroCommitTimestamp() public {
        // When commit timestamp is 0 (batch was committed outside timelock or not committed),
        // execution is allowed as long as block.timestamp >= delay
        uint64 batchNumber = 999;

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        storedBatch.batchNumber = batchNumber;
        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = storedBatch;

        vm.mockCall(
            zkSync,
            abi.encodeWithSelector(IExecutor.executeBatchesSharedBridge.selector),
            abi.encode(storedBatches)
        );

        // No commit was done, so timestamp is 0
        assertEq(validator.getCommittedBatchTimestamp(zkSync, batchNumber), 0);

        // Warp to a time greater than executionDelay (block.timestamp must be >= 0 + delay)
        vm.warp(executionDelay + 1);

        vm.prank(alice);
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatches,
            Utils.emptyData()
        );
        validator.executeBatchesSharedBridge(zkSync, executeBatchFrom, executeBatchTo, executeData);
    }

    function test_commitBatches_MultipleBatches() public {
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatchesSharedBridge.selector), abi.encode(chainId));

        uint64 timestamp = 123456;
        uint64 batchNumberStart = 10;

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batch1 = Utils.createCommitBatchInfo();
        IExecutor.CommitBatchInfo memory batch2 = Utils.createCommitBatchInfo();
        IExecutor.CommitBatchInfo memory batch3 = Utils.createCommitBatchInfo();

        batch1.batchNumber = batchNumberStart;
        batch2.batchNumber = batchNumberStart + 1;
        batch3.batchNumber = batchNumberStart + 2;

        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](3);
        batchesToCommit[0] = batch1;
        batchesToCommit[1] = batch2;
        batchesToCommit[2] = batch3;

        vm.warp(timestamp);
        vm.prank(alice);
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            storedBatch,
            batchesToCommit
        );
        validator.commitBatchesSharedBridge(zkSync, commitBatchFrom, commitBatchTo, commitData);

        // All 3 batches should have the same timestamp
        assertEq(validator.getCommittedBatchTimestamp(zkSync, batchNumberStart), timestamp);
        assertEq(validator.getCommittedBatchTimestamp(zkSync, batchNumberStart + 1), timestamp);
        assertEq(validator.getCommittedBatchTimestamp(zkSync, batchNumberStart + 2), timestamp);
    }
}
