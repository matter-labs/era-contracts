// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Utils} from "./Utils/Utils.sol";
import {ValidatorTimelock, IExecutor} from "solpp/state-transition/ValidatorTimelock.sol";
import {DummyStateTransitionManagerForValidatorTimelock} from "solpp/dev-contracts/test/DummyStateTransitionManagerForValidatorTimelock.sol";
import {IStateTransitionManager} from "solpp/state-transition/IStateTransitionManager.sol";

contract ValidatorTimelockTest is Test {
    /// @notice A new validator has been added.
    event ValidatorAdded(uint256 _chainId, address _addedValidator);

    /// @notice A validator has been removed.
    event ValidatorRemoved(uint256 _chainId, address _removedValidator);

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
    uint256 chainId;

    function setUp() public {
        owner = makeAddr("owner");
        zkSync = makeAddr("zkSync");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        chainId = 1;

        stateTransitionManager = new DummyStateTransitionManagerForValidatorTimelock(owner, zkSync);
        validator = new ValidatorTimelock(owner, 10);
        vm.prank(owner);
        validator.setStateTransitionManager(IStateTransitionManager(address(stateTransitionManager)));
        vm.prank(owner);
        validator.addValidator(chainId, alice);
    }

    function test_addValidator() public {
        assert(validator.validators(chainId, bob) == false);

        vm.prank(owner);
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

    function test_addValidator_revertWhenNotAdmin() public {
        assert(validator.validators(chainId, bob) == false);

        vm.expectRevert("ValidatorTimelock: only chain admin");
        validator.addValidator(chainId, bob);

        assert(validator.validators(chainId, bob) == false);
    }

    function test_removeValidator_revertWhenNotAdmin() public {
        assert(validator.validators(chainId, alice) == true);

        vm.expectRevert("ValidatorTimelock: only chain admin");
        validator.removeValidator(chainId, alice);

        assert(validator.validators(chainId, alice) == true);
    }

    function test_addValidator_revertWhenAddressAlreadyValidator() public {
        assert(validator.validators(chainId, alice) == true);

        vm.prank(owner);
        vm.expectRevert(abi.encodePacked(AddressAlreadyValidator.selector, chainId));
        validator.addValidator(chainId, alice);
    }

    function test_removeValidator_revertWhenAddressNotValidator() public {
        assert(validator.validators(chainId, bob) == false);

        vm.prank(owner);
        vm.expectRevert(abi.encodePacked(ValidatorDoesNotExist.selector, chainId));
        validator.removeValidator(chainId, bob);
    }

    function test_validatorCanMakeCall_revertWhenNotValidator() public {
        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(bob);
        vm.expectRevert(bytes("ValidatorTimelock: only validator"));
        validator.commitBatches(storedBatch, batchesToCommit);
    }
}
