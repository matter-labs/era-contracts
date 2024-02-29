// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {Utils} from "./Utils/Utils.sol";
import {ValidatorTimelock, IExecutor} from "solpp/zksync/ValidatorTimelock.sol";

contract ValidatorTimelockTest is Test {
    /// @notice Event emitted from ValidatorTimelock when new validator is added
    event ValidatorAdded(address _addedValidator);

    /// @notice Event emitted from ValidatorTimelock when new validator is removed
    event ValidatorRemoved(address _removedValidator);

    /// @notice Error for when an address is already a validator.
    error AddressAlreadyValidator();

    /// @notice Error for when an address is not a validator.
    error ValidatorDoesNotExist();

    ValidatorTimelock validator;

    address owner;
    address zkSync;
    address alice;
    address bob;

    function setUp() public {
        owner = makeAddr("owner");
        zkSync = makeAddr("zkSync");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        address[] memory initValidators = new address[](1);
        initValidators[0] = alice;

        validator = new ValidatorTimelock(owner, zkSync, 10, initValidators);
    }

    function test_addValidator() public {
        assert(validator.validators(bob) == false);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(validator));
        emit ValidatorAdded(bob);
        validator.addValidator(bob);

        assert(validator.validators(bob) == true);
    }

    function test_removeValidator() public {
        vm.prank(owner);
        validator.addValidator(bob);
        assert(validator.validators(bob) == true);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(validator));
        emit ValidatorRemoved(bob);
        validator.removeValidator(bob);

        assert(validator.validators(bob) == false);
    }

    function test_validatorCanMakeCall() public {
        // Setup Mock call to executor
        vm.mockCall(zkSync, abi.encodeWithSelector(IExecutor.commitBatches.selector), "");

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(alice);
        validator.commitBatches(storedBatch, batchesToCommit);
    }

    function test_addValidator_revertWhenNotOwner() public {
        assert(validator.validators(bob) == false);

        vm.expectRevert("Ownable: caller is not the owner");
        validator.addValidator(bob);

        assert(validator.validators(bob) == false);
    }

    function test_removeValidator_revertWhenNotOwner() public {
        assert(validator.validators(alice) == true);

        vm.expectRevert("Ownable: caller is not the owner");
        validator.removeValidator(alice);

        assert(validator.validators(alice) == true);
    }

    function test_addValidator_revertWhenAddressAlreadyValidator() public {
        assert(validator.validators(alice) == true);

        vm.prank(owner);
        vm.expectRevert(AddressAlreadyValidator.selector);
        validator.addValidator(alice);
    }

    function test_removeValidator_revertWhenAddressNotValidator() public {
        assert(validator.validators(bob) == false);

        vm.prank(owner);
        vm.expectRevert(ValidatorDoesNotExist.selector);
        validator.removeValidator(bob);
    }

    function test_validatorCanMakeCall_revertWhenNotValidator() public {
        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        vm.prank(bob);
        vm.expectRevert(bytes("8h"));
        validator.commitBatches(storedBatch, batchesToCommit);
    }
}
