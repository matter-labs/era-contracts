// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Utils} from "../Utils/Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfo, ICommitter} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {DummyChainTypeManagerForValidatorTimelock} from "contracts/dev-contracts/test/DummyChainTypeManagerForValidatorTimelock.sol";

import {
    ExecutionDelayNotIncreased,
    ExecutionDelayTooLarge,
    NotAZKChain,
    RoleAccessDenied,
    TimeNotReached
} from "contracts/common/L1ContractErrors.sol";
import {IValidatorTimelock} from "contracts/state-transition/validators/interfaces/IValidatorTimelock.sol";
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
    bytes32 upgraderRole;
    bytes32 precommitterAdminRole;
    bytes32 committerAdminRole;
    bytes32 reverterAdminRole;
    bytes32 proverAdminRole;
    bytes32 executorAdminRole;
    bytes32 upgraderAdminRole;

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
        upgraderRole = validator.UPGRADER_ROLE();
        precommitterAdminRole = validator.OPTIONAL_PRECOMMITTER_ADMIN_ROLE();
        committerAdminRole = validator.OPTIONAL_COMMITTER_ADMIN_ROLE();
        reverterAdminRole = validator.OPTIONAL_REVERTER_ADMIN_ROLE();
        proverAdminRole = validator.OPTIONAL_PROVER_ADMIN_ROLE();
        executorAdminRole = validator.OPTIONAL_EXECUTOR_ADMIN_ROLE();
        upgraderAdminRole = validator.OPTIONAL_UPGRADER_ADMIN_ROLE();
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

    /// @dev Commits a single batch `_batchNumber` at the current block timestamp through the timelock.
    function _commitSingleBatch(uint64 _batchNumber) internal {
        vm.mockCall(zkSync, abi.encodeWithSelector(ICommitter.commitBatchesSharedBridge.selector), abi.encode(chainId));

        CommitBatchInfo[] memory batchesToCommit = new CommitBatchInfo[](1);
        batchesToCommit[0] = Utils.createCommitBatchInfo();
        batchesToCommit[0].batchNumber = _batchNumber;

        (uint256 batchFrom, uint256 batchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            Utils.createStoredBatchInfo(),
            batchesToCommit
        );
        vm.prank(alice);
        validator.commitBatchesSharedBridge(zkSync, batchFrom, batchTo, commitData);
    }

    /// @dev Encodes the `executeBatchesSharedBridge` arguments for a single batch `_batchNumber`.
    function _encodeExecuteSingleBatch(
        uint64 _batchNumber
    ) internal returns (uint256 batchFrom, uint256 batchTo, bytes memory executeData) {
        IExecutor.StoredBatchInfo[] memory storedBatches = new IExecutor.StoredBatchInfo[](1);
        storedBatches[0] = Utils.createStoredBatchInfo();
        storedBatches[0].batchNumber = _batchNumber;

        vm.mockCall(
            zkSync,
            abi.encodeWithSelector(IExecutor.executeBatchesSharedBridge.selector),
            abi.encode(storedBatches)
        );

        return Utils.encodeExecuteBatchesData(storedBatches, Utils.emptyData());
    }

    function _assertAllRoles(uint256 _chainId, address _addr, bool _expected) internal view {
        require(validator.hasRoleForChainId(_chainId, validator.PRECOMMITTER_ROLE(), _addr) == _expected);
        require(validator.hasRoleForChainId(_chainId, validator.COMMITTER_ROLE(), _addr) == _expected);
        require(validator.hasRoleForChainId(_chainId, validator.REVERTER_ROLE(), _addr) == _expected);
        require(validator.hasRoleForChainId(_chainId, validator.PROVER_ROLE(), _addr) == _expected);
        require(validator.hasRoleForChainId(_chainId, validator.EXECUTOR_ROLE(), _addr) == _expected);
        require(validator.hasRoleForChainId(_chainId, validator.UPGRADER_ROLE(), _addr) == _expected);
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
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleGranted(zkSync, upgraderRole, bob);
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
        vm.expectEmit(true, true, true, true, address(validator));
        emit AccessControlEnumerablePerChainAddressUpgradeable.RoleRevoked(zkSync, upgraderRole, bob);
        validator.removeValidatorForChainId(chainId, bob);

        _assertAllRoles(chainId, bob, false);
    }

    function test_validatorCanMakeCall() public {
        // Setup Mock call to executor
        vm.mockCall(zkSync, abi.encodeWithSelector(ICommitter.commitBatchesSharedBridge.selector), "");

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        CommitBatchInfo[] memory batchesToCommit = new CommitBatchInfo[](1);
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
            abi.encodeWithSelector(ICommitter.commitBatchesSharedBridge.selector),
            abi.encode(eraChainId)
        );

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        batchToCommit.batchNumber = batchNumber;
        CommitBatchInfo[] memory batchesToCommit = new CommitBatchInfo[](1);
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
        vm.mockCall(zkSync, abi.encodeWithSelector(ICommitter.commitBatchesSharedBridge.selector), abi.encode(chainId));

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        CommitBatchInfo[] memory batchesToCommit = new CommitBatchInfo[](1);
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

    function test_upgradeChainFromVersion_PropagatesToDiamondProxy() public {
        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.mockCall(
            zkSync,
            abi.encodeCall(IAdmin.upgradeChainFromVersion, (zkSync, oldProtocolVersion, diamondCut)),
            ""
        );
        vm.expectCall(zkSync, abi.encodeCall(IAdmin.upgradeChainFromVersion, (zkSync, oldProtocolVersion, diamondCut)));

        vm.prank(alice);
        validator.upgradeChainFromVersion(zkSync, oldProtocolVersion, diamondCut);
    }

    function test_RevertWhen_upgradeChainFromVersionNotUpgrader() public {
        uint256 oldProtocolVersion = 1;
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: address(0),
            initCalldata: bytes("")
        });

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, upgraderRole, bob));
        validator.upgradeChainFromVersion(zkSync, oldProtocolVersion, diamondCut);
    }

    function test_executeBatchesSharedBridge() public {
        uint64 timestamp = 123456;
        uint64 batchNumber = 123;

        // Commit batches first to have the valid timestamp
        vm.warp(timestamp);
        _commitSingleBatch(batchNumber);

        (uint256 batchFrom, uint256 batchTo, bytes memory executeData) = _encodeExecuteSingleBatch(batchNumber);

        vm.warp(timestamp + executionDelay + 1);
        vm.prank(alice);
        validator.executeBatchesSharedBridge(zkSync, batchFrom, batchTo, executeData);
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
        CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        CommitBatchInfo[] memory batchesToCommit = new CommitBatchInfo[](1);
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
        (uint256 batchFrom, uint256 batchTo, bytes memory executeData) = _encodeExecuteSingleBatch(123);

        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, executorRole, bob));
        vm.prank(bob);
        validator.executeBatchesSharedBridge(zkSync, batchFrom, batchTo, executeData);
    }

    function test_RevertWhen_executeBatchesSharedBridgeTooEarly() public {
        uint64 timestamp = 123456;
        uint64 batchNumber = 123;

        vm.warp(timestamp);
        _commitSingleBatch(batchNumber);

        (uint256 batchFrom, uint256 batchTo, bytes memory executeData) = _encodeExecuteSingleBatch(batchNumber);

        vm.warp(timestamp + executionDelay - 1);
        vm.expectRevert(abi.encodeWithSelector(TimeNotReached.selector, timestamp + executionDelay, block.timestamp));
        vm.prank(alice);
        validator.executeBatchesSharedBridge(zkSync, batchFrom, batchTo, executeData);
    }

    function test_addValidatorRoles_PartialRoles() public {
        // Add only precommitter and committer roles
        IValidatorTimelock.ValidatorRotationParams memory params = IValidatorTimelock.ValidatorRotationParams({
            rotatePrecommitterRole: true,
            rotateCommitterRole: true,
            rotateReverterRole: false,
            rotateProverRole: false,
            rotateExecutorRole: false,
            rotateUpgraderRole: false
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
            rotateExecutorRole: false,
            rotateUpgraderRole: false
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
            rotateExecutorRole: true,
            rotateUpgraderRole: false
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
        vm.mockCall(zkSync, abi.encodeWithSelector(ICommitter.precommitSharedBridge.selector), "");

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
            rotateExecutorRole: false,
            rotateUpgraderRole: false
        });

        vm.expectRevert(abi.encodeWithSelector(NotAZKChain.selector, fakeChain));
        validator.addValidatorRoles(fakeChain, bob, params);
    }

    function test_executeBatchesSharedBridge_ZeroCommitTimestamp() public {
        // When commit timestamp is 0 (batch was committed outside timelock or not committed),
        // execution is allowed as long as block.timestamp >= delay
        uint64 batchNumber = 999;

        (uint256 batchFrom, uint256 batchTo, bytes memory executeData) = _encodeExecuteSingleBatch(batchNumber);

        // No commit was done, so timestamp is 0
        assertEq(validator.getCommittedBatchTimestamp(zkSync, batchNumber), 0);

        // Warp to a time greater than executionDelay (block.timestamp must be >= 0 + delay)
        vm.warp(executionDelay + 1);

        vm.prank(alice);
        validator.executeBatchesSharedBridge(zkSync, batchFrom, batchTo, executeData);
    }

    function test_commitBatches_MultipleBatches() public {
        vm.mockCall(zkSync, abi.encodeWithSelector(ICommitter.commitBatchesSharedBridge.selector), abi.encode(chainId));

        uint64 timestamp = 123456;
        uint64 batchNumberStart = 10;

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        CommitBatchInfo memory batch1 = Utils.createCommitBatchInfo();
        CommitBatchInfo memory batch2 = Utils.createCommitBatchInfo();
        CommitBatchInfo memory batch3 = Utils.createCommitBatchInfo();

        batch1.batchNumber = batchNumberStart;
        batch2.batchNumber = batchNumberStart + 1;
        batch3.batchNumber = batchNumberStart + 2;

        CommitBatchInfo[] memory batchesToCommit = new CommitBatchInfo[](3);
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

    /*//////////////////////////////////////////////////////////////
                        PER-CHAIN EXECUTION DELAY
    //////////////////////////////////////////////////////////////*/

    /// @dev Re-points the mocked `getAdmin` of the ZK chain so that the chain admin is a different
    /// address than the owner of the `ValidatorTimelock`. This is required to tell the two apart:
    /// in `setUp` both roles are held by `owner`.
    function _setChainAdmin(address _newAdmin) internal {
        vm.mockCall(zkSync, abi.encodeCall(IGetters.getAdmin, ()), abi.encode(_newAdmin));
    }

    function test_getExecutionDelay_defaultsToEcosystemDelay() public view {
        assertEq(validator.chainExecutionDelay(zkSync), 0);
        assertEq(validator.getExecutionDelay(zkSync), executionDelay);
    }

    function test_increaseChainExecutionDelay() public {
        // The chain admin is deliberately not the owner of the timelock here.
        _setChainAdmin(bob);
        uint32 newDelay = executionDelay + 5;

        vm.expectEmit(true, true, true, true, address(validator));
        emit IValidatorTimelock.NewChainExecutionDelay(zkSync, newDelay);
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, newDelay);

        assertEq(validator.chainExecutionDelay(zkSync), newDelay);
        assertEq(validator.getExecutionDelay(zkSync), newDelay);
        // The ecosystem-wide value is untouched.
        assertEq(validator.executionDelay(), executionDelay);
    }

    function test_increaseChainExecutionDelay_multipleTimes() public {
        _setChainAdmin(bob);

        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, 100);
        assertEq(validator.getExecutionDelay(zkSync), 100);

        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, 200);
        assertEq(validator.getExecutionDelay(zkSync), 200);
    }

    /// @dev The cap is an inclusive bound, so a chain may raise its delay exactly up to it.
    function test_increaseChainExecutionDelay_upToMax() public {
        uint32 maxDelay = validator.MAX_EXECUTION_DELAY();
        assertEq(maxDelay, 7 days);

        _setChainAdmin(bob);
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, maxDelay);

        assertEq(validator.getExecutionDelay(zkSync), maxDelay);
    }

    /// @dev The ecosystem-wide delay is a lower bound: raising it above a chain's own value takes
    /// precedence, while lowering it again leaves the chain's own choice in effect.
    function test_getExecutionDelay_ecosystemDelayIsAFloor() public {
        _setChainAdmin(bob);
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, 100);

        vm.prank(owner);
        validator.setExecutionDelay(200);
        assertEq(validator.chainExecutionDelay(zkSync), 100);
        assertEq(validator.getExecutionDelay(zkSync), 200);

        vm.prank(owner);
        validator.setExecutionDelay(50);
        assertEq(validator.getExecutionDelay(zkSync), 100);
    }

    function test_setChainExecutionDelay_ownerCanDecrease() public {
        _setChainAdmin(bob);
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, 1000);
        assertEq(validator.getExecutionDelay(zkSync), 1000);

        // The owner of the timelock is not the chain admin at this point, yet it is the only
        // party able to bring the chain-specific delay back down.
        vm.expectEmit(true, true, true, true, address(validator));
        emit IValidatorTimelock.NewChainExecutionDelay(zkSync, 0);
        vm.prank(owner);
        validator.setChainExecutionDelay(zkSync, 0);

        assertEq(validator.chainExecutionDelay(zkSync), 0);
        assertEq(validator.getExecutionDelay(zkSync), executionDelay);
    }

    /// @dev The chain-specific delay is what `executeBatchesSharedBridge` actually enforces.
    function test_executeBatches_respectsChainExecutionDelay() public {
        uint32 chainDelay = 1 days;
        _setChainAdmin(bob);
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, chainDelay);

        uint64 batchNumber = 10;
        uint64 commitTimestamp = 123456;

        vm.warp(commitTimestamp);
        _commitSingleBatch(batchNumber);

        (uint256 batchFrom, uint256 batchTo, bytes memory executeData) = _encodeExecuteSingleBatch(batchNumber);

        // The ecosystem-wide delay has long passed, but the chain-specific one has not.
        vm.warp(commitTimestamp + executionDelay + 1);
        vm.expectRevert(abi.encodeWithSelector(TimeNotReached.selector, commitTimestamp + chainDelay, block.timestamp));
        vm.prank(alice);
        validator.executeBatchesSharedBridge(zkSync, batchFrom, batchTo, executeData);

        vm.warp(commitTimestamp + chainDelay);
        vm.prank(alice);
        validator.executeBatchesSharedBridge(zkSync, batchFrom, batchTo, executeData);
    }

    function test_RevertWhen_increaseChainExecutionDelayNotChainAdmin() public {
        _setChainAdmin(bob);

        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, DEFAULT_ADMIN_ROLE, alice));
        vm.prank(alice);
        validator.increaseChainExecutionDelay(zkSync, 1000);

        assertEq(validator.chainExecutionDelay(zkSync), 0);
    }

    /// @dev Being the owner of the timelock does not by itself grant the right to raise a chain's delay.
    function test_RevertWhen_increaseChainExecutionDelayOwnerNotChainAdmin() public {
        _setChainAdmin(bob);

        vm.expectRevert(abi.encodeWithSelector(RoleAccessDenied.selector, zkSync, DEFAULT_ADMIN_ROLE, owner));
        vm.prank(owner);
        validator.increaseChainExecutionDelay(zkSync, 1000);
    }

    function test_RevertWhen_increaseChainExecutionDelayAboveMax() public {
        uint32 maxDelay = validator.MAX_EXECUTION_DELAY();
        _setChainAdmin(bob);

        vm.expectRevert(abi.encodeWithSelector(ExecutionDelayTooLarge.selector, maxDelay + 1, maxDelay));
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, maxDelay + 1);
    }

    /// @dev A chain that has not set its own delay yet must still clear the ecosystem-wide one,
    /// otherwise the call would be a no-op.
    function test_RevertWhen_increaseChainExecutionDelayEqualToEcosystemDelay() public {
        _setChainAdmin(bob);

        vm.expectRevert(abi.encodeWithSelector(ExecutionDelayNotIncreased.selector, executionDelay, executionDelay));
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, executionDelay);
    }

    function test_RevertWhen_increaseChainExecutionDelayBelowEcosystemDelay() public {
        _setChainAdmin(bob);

        vm.expectRevert(
            abi.encodeWithSelector(ExecutionDelayNotIncreased.selector, executionDelay, executionDelay - 1)
        );
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, executionDelay - 1);
    }

    /// @dev The core property of this feature: a chain admin cannot walk back a delay it raised.
    function test_RevertWhen_increaseChainExecutionDelayDecreasesOwnValue() public {
        _setChainAdmin(bob);
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, 1000);

        vm.expectRevert(abi.encodeWithSelector(ExecutionDelayNotIncreased.selector, 1000, 999));
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, 999);

        assertEq(validator.getExecutionDelay(zkSync), 1000);
    }

    function test_RevertWhen_setChainExecutionDelayNotOwner() public {
        // Even the chain admin cannot use the owner-only setter to lower the delay.
        _setChainAdmin(bob);
        vm.prank(bob);
        validator.increaseChainExecutionDelay(zkSync, 1000);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(bob);
        validator.setChainExecutionDelay(zkSync, 0);

        assertEq(validator.getExecutionDelay(zkSync), 1000);
    }

    function test_RevertWhen_setChainExecutionDelayAboveMax() public {
        uint32 maxDelay = validator.MAX_EXECUTION_DELAY();

        vm.expectRevert(abi.encodeWithSelector(ExecutionDelayTooLarge.selector, maxDelay + 1, maxDelay));
        vm.prank(owner);
        validator.setChainExecutionDelay(zkSync, maxDelay + 1);
    }

    function test_RevertWhen_setExecutionDelayAboveMax() public {
        uint32 maxDelay = validator.MAX_EXECUTION_DELAY();

        vm.expectRevert(abi.encodeWithSelector(ExecutionDelayTooLarge.selector, maxDelay + 1, maxDelay));
        vm.prank(owner);
        validator.setExecutionDelay(maxDelay + 1);
    }

    function test_RevertWhen_initialExecutionDelayAboveMax() public {
        uint32 maxDelay = validator.MAX_EXECUTION_DELAY();

        // The proxy admin and the implementation are deployed upfront so that `expectRevert`
        // applies to the proxy deployment, i.e. to the initializer call itself.
        ProxyAdmin admin = new ProxyAdmin();
        ValidatorTimelock timelockImplementation = new ValidatorTimelock(address(dummyBridgehub));

        vm.expectRevert(abi.encodeWithSelector(ExecutionDelayTooLarge.selector, maxDelay + 1, maxDelay));
        new TransparentUpgradeableProxy(
            address(timelockImplementation),
            address(admin),
            abi.encodeCall(ValidatorTimelock.initialize, (owner, maxDelay + 1))
        );
    }

    function testFuzz_getExecutionDelayIsTheMaximumOfBothValues(uint32 _ecosystemDelay, uint32 _chainDelay) public {
        uint32 maxDelay = validator.MAX_EXECUTION_DELAY();
        _ecosystemDelay = uint32(bound(_ecosystemDelay, 0, maxDelay));
        _chainDelay = uint32(bound(_chainDelay, 0, maxDelay));

        vm.startPrank(owner);
        validator.setExecutionDelay(_ecosystemDelay);
        validator.setChainExecutionDelay(zkSync, _chainDelay);
        vm.stopPrank();

        uint32 expected = _chainDelay > _ecosystemDelay ? _chainDelay : _ecosystemDelay;
        assertEq(validator.getExecutionDelay(zkSync), expected);
    }
}
