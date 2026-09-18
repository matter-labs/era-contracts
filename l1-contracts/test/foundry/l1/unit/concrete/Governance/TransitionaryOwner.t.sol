// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransitionaryOwner} from "contracts/governance/TransitionaryOwner.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

/// @notice Mock Ownable2Step contract for testing TransitionaryOwner
contract MockOwnable2Step is Ownable2Step {
    constructor(address _initialOwner) {
        _transferOwnership(_initialOwner);
    }

    // Expose internal function for testing
    function internalTransferOwnership(address newOwner) external {
        _transferOwnership(newOwner);
    }
}

/// @notice Unit tests for TransitionaryOwner contract
contract TransitionaryOwnerTest is Test {
    TransitionaryOwner internal transitionaryOwner;
    MockOwnable2Step internal mockOwnableContract;

    address internal governanceAddress;
    address internal initialOwner;
    address internal randomUser;

    function setUp() public {
        governanceAddress = makeAddr("governance");
        initialOwner = makeAddr("initialOwner");
        randomUser = makeAddr("randomUser");

        transitionaryOwner = new TransitionaryOwner(governanceAddress);
        mockOwnableContract = new MockOwnable2Step(initialOwner);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsGovernanceAddress() public view {
        assertEq(transitionaryOwner.GOVERNANCE_ADDRESS(), governanceAddress);
    }

    function test_constructor_acceptsZeroGovernanceAddress() public {
        TransitionaryOwner transitionaryWithZero = new TransitionaryOwner(address(0));
        assertEq(transitionaryWithZero.GOVERNANCE_ADDRESS(), address(0));
    }

    function test_constructor_fuzz(address _governanceAddress) public {
        TransitionaryOwner transitionaryFuzz = new TransitionaryOwner(_governanceAddress);
        assertEq(transitionaryFuzz.GOVERNANCE_ADDRESS(), _governanceAddress);
    }

    // ============ claimOwnershipAndGiveToGovernance Tests ============

    function test_claimOwnershipAndGiveToGovernance_transfersOwnership() public {
        // First, current owner initiates transfer to transitionaryOwner
        vm.prank(initialOwner);
        mockOwnableContract.transferOwnership(address(transitionaryOwner));

        // Verify transitionaryOwner is pending owner
        assertEq(mockOwnableContract.pendingOwner(), address(transitionaryOwner));

        // Call claimOwnershipAndGiveToGovernance
        transitionaryOwner.claimOwnershipAndGiveToGovernance(address(mockOwnableContract));

        // Verify governance is now the pending owner (Ownable2Step requires acceptance)
        assertEq(mockOwnableContract.pendingOwner(), governanceAddress);

        // Governance accepts ownership
        vm.prank(governanceAddress);
        mockOwnableContract.acceptOwnership();

        // Verify governance is now the owner
        assertEq(mockOwnableContract.owner(), governanceAddress);
    }

    function test_claimOwnershipAndGiveToGovernance_canBeCalledByAnyone() public {
        // Setup: transfer to transitionaryOwner
        vm.prank(initialOwner);
        mockOwnableContract.transferOwnership(address(transitionaryOwner));

        // Any user can call the function
        vm.prank(randomUser);
        transitionaryOwner.claimOwnershipAndGiveToGovernance(address(mockOwnableContract));

        // Verify governance is now the pending owner
        assertEq(mockOwnableContract.pendingOwner(), governanceAddress);
    }

    function test_claimOwnershipAndGiveToGovernance_revertsIfNotPendingOwner() public {
        // Don't transfer to transitionaryOwner, so it's not the pending owner

        vm.expectRevert("Ownable2Step: caller is not the new owner");
        transitionaryOwner.claimOwnershipAndGiveToGovernance(address(mockOwnableContract));
    }

    function test_claimOwnershipAndGiveToGovernance_emitsOwnershipTransferredEvents() public {
        // Setup: transfer to transitionaryOwner
        vm.prank(initialOwner);
        mockOwnableContract.transferOwnership(address(transitionaryOwner));

        // Expect ownership events
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(initialOwner, address(transitionaryOwner));

        transitionaryOwner.claimOwnershipAndGiveToGovernance(address(mockOwnableContract));
    }

    function test_claimOwnershipAndGiveToGovernance_withZeroGovernance() public {
        // Create transitionaryOwner with zero governance address
        TransitionaryOwner transitionaryWithZero = new TransitionaryOwner(address(0));

        // Create new ownable contract
        MockOwnable2Step newOwnable = new MockOwnable2Step(initialOwner);

        // Setup: transfer to transitionaryWithZero
        vm.prank(initialOwner);
        newOwnable.transferOwnership(address(transitionaryWithZero));

        // Call should still work (transfers to zero address)
        transitionaryWithZero.claimOwnershipAndGiveToGovernance(address(newOwnable));

        // Zero address should be the pending owner
        assertEq(newOwnable.pendingOwner(), address(0));
    }

    function test_claimOwnershipAndGiveToGovernance_multipleContracts() public {
        // Create multiple ownable contracts
        MockOwnable2Step ownable1 = new MockOwnable2Step(initialOwner);
        MockOwnable2Step ownable2 = new MockOwnable2Step(initialOwner);

        // Transfer both to transitionaryOwner
        vm.startPrank(initialOwner);
        ownable1.transferOwnership(address(transitionaryOwner));
        ownable2.transferOwnership(address(transitionaryOwner));
        vm.stopPrank();

        // Claim both
        transitionaryOwner.claimOwnershipAndGiveToGovernance(address(ownable1));
        transitionaryOwner.claimOwnershipAndGiveToGovernance(address(ownable2));

        // Both should have governance as pending owner
        assertEq(ownable1.pendingOwner(), governanceAddress);
        assertEq(ownable2.pendingOwner(), governanceAddress);
    }

    function test_claimOwnershipAndGiveToGovernance_cannotCallTwice() public {
        // Setup: transfer to transitionaryOwner
        vm.prank(initialOwner);
        mockOwnableContract.transferOwnership(address(transitionaryOwner));

        // First call succeeds
        transitionaryOwner.claimOwnershipAndGiveToGovernance(address(mockOwnableContract));

        // Second call should fail because transitionaryOwner is no longer the owner
        // and cannot initiate another transfer
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        transitionaryOwner.claimOwnershipAndGiveToGovernance(address(mockOwnableContract));
    }

    // ============ Event Declaration ============

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
}
