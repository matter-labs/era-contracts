// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ReentrancyGuard} from "contracts/common/ReentrancyGuard.sol";
import {NotInitializedReentrancyGuard, Reentrancy, SlotOccupied} from "contracts/common/L1ContractErrors.sol";

/// @notice Test contract that uses ReentrancyGuard
contract ReentrancyGuardMock is ReentrancyGuard {
    uint256 public counter;
    address public attacker;
    bool public callbackReverted;

    function initialize() external reentrancyGuardInitializer {}

    function incrementNonReentrant() external nonReentrant {
        counter += 1;

        // If attacker is set, call it (for reentrancy attack simulation)
        if (attacker != address(0)) {
            (bool success, ) = attacker.call(abi.encodeWithSignature("attack()"));
            if (!success) {
                callbackReverted = true;
            }
        }
    }

    function incrementNoGuard() external {
        counter += 1;
    }

    function setAttacker(address _attacker) external {
        attacker = _attacker;
    }
}

/// @notice Attacker contract that tries to re-enter
contract ReentrancyAttacker {
    ReentrancyGuardMock public target;
    uint256 public attackCount;

    constructor(address _target) {
        target = ReentrancyGuardMock(_target);
    }

    function attack() external {
        attackCount++;
        target.incrementNonReentrant();
    }

    function startAttack() external {
        target.incrementNonReentrant();
    }
}

/// @notice Unit tests for ReentrancyGuard
contract ReentrancyGuardTest is Test {
    ReentrancyGuardMock public guard;
    ReentrancyAttacker public attacker;

    function setUp() public {
        guard = new ReentrancyGuardMock();
    }

    // ============ reentrancyGuardInitializer Tests ============

    function test_initialize_setsGuard() public {
        guard.initialize();

        // Should be able to call nonReentrant function after initialization
        guard.incrementNonReentrant();
        assertEq(guard.counter(), 1);
    }

    function test_initialize_revertsOnDoubleInit() public {
        guard.initialize();

        vm.expectRevert(SlotOccupied.selector);
        guard.initialize();
    }

    // ============ nonReentrant Tests ============

    function test_nonReentrant_allowsNormalCalls() public {
        guard.initialize();

        guard.incrementNonReentrant();
        guard.incrementNonReentrant();
        guard.incrementNonReentrant();

        assertEq(guard.counter(), 3);
    }

    function test_nonReentrant_revertsIfNotInitialized() public {
        vm.expectRevert(NotInitializedReentrancyGuard.selector);
        guard.incrementNonReentrant();
    }

    function test_nonReentrant_preventsReentrancy() public {
        guard.initialize();

        attacker = new ReentrancyAttacker(address(guard));
        guard.setAttacker(address(attacker));

        // The reentrancy attack fails inside the callback, but the outer call succeeds
        guard.incrementNonReentrant();

        // The callback should have reverted due to reentrancy
        assertTrue(guard.callbackReverted());
        // Counter should be 1 (first increment succeeded, reentrant one failed)
        assertEq(guard.counter(), 1);
    }

    function test_nonReentrant_resetsAfterCall() public {
        guard.initialize();

        guard.incrementNonReentrant();

        // Should be able to call again after first call completes
        guard.incrementNonReentrant();

        assertEq(guard.counter(), 2);
    }

    function test_nonReentrant_doesNotAffectOtherFunctions() public {
        guard.initialize();

        // Non-guarded function should always work
        guard.incrementNoGuard();
        guard.incrementNoGuard();

        assertEq(guard.counter(), 2);
    }

    function test_nonReentrant_multipleSequentialCalls() public {
        guard.initialize();

        for (uint256 i = 0; i < 10; i++) {
            guard.incrementNonReentrant();
        }

        assertEq(guard.counter(), 10);
    }

    // ============ Integration Tests ============

    function test_reentrancyAttack_fails() public {
        guard.initialize();

        attacker = new ReentrancyAttacker(address(guard));
        guard.setAttacker(address(attacker));

        // The attacker's startAttack calls incrementNonReentrant which tries to reenter
        attacker.startAttack();

        // The callback should have reverted due to reentrancy
        assertTrue(guard.callbackReverted());
        // Counter should be 1 (first increment succeeded, reentrant one failed)
        assertEq(guard.counter(), 1);
    }

    function test_directReentrantCall_fails() public {
        guard.initialize();

        // Create a contract that calls back
        ReentrantCallback callback = new ReentrantCallback(address(guard));
        guard.setAttacker(address(callback));

        // The outer call succeeds but the reentrant callback fails
        guard.incrementNonReentrant();

        // The callback should have reverted due to reentrancy
        assertTrue(guard.callbackReverted());
        // Counter should be 1 (first increment succeeded, reentrant one failed)
        assertEq(guard.counter(), 1);
    }
}

/// @notice Callback contract for testing reentrancy
contract ReentrantCallback {
    ReentrancyGuardMock public target;

    constructor(address _target) {
        target = ReentrancyGuardMock(_target);
    }

    fallback() external {
        target.incrementNonReentrant();
    }
}
