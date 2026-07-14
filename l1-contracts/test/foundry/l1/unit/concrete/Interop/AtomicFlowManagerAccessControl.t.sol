// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {ManagerNotInteropCenter, ManagerNotInteropHandler} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {AtomicFinalityProof} from "contracts/atomic-interop/IAtomicInterop.sol";

/// @title AtomicFlowManagerAccessControlTest
/// @notice Caller-authentication tests for the atomic-interop flow manager.
/// @dev This is the atomic counterpart of the removed public-path `messageNotFromInteropCenter` test. Public
///      interop authenticated a bundle by checking that its L1 message was sent by the canonical InteropCenter
///      (`_verifyBundle`). Atomic interop authenticates differently but equivalently: only the InteropCenter
///      may commit a bundle to the IMT (`append`), and only the InteropHandler may invoke the finality gate
///      (`requireFlowFinalized`). Combined with the per-leg IMT inclusion proof, `append` being
///      InteropCenter-only is what makes a finalized bundle provably InteropCenter-authored — so a forged
///      bundle can never be committed, hence never finalized, hence never executed. These tests pin those two
///      gates. `commitmentTree()` is never reached: the modifier reverts first.
contract AtomicFlowManagerAccessControlTest is Test {
    AtomicFlowManager internal manager;

    function setUp() public {
        manager = new AtomicFlowManager();
    }

    /// @notice `append` (the sole IMT-commit / bundle-authoring entry point) rejects any caller other than the
    ///         InteropCenter — the atomic replacement for the public `message.sender == InteropCenter` check.
    function test_append_revertsWhen_callerNotInteropCenter() public {
        address notInteropCenter = makeAddr("notInteropCenter");
        vm.prank(notInteropCenter);
        vm.expectRevert(abi.encodeWithSelector(ManagerNotInteropCenter.selector, notInteropCenter));
        manager.append(bytes32(0), bytes32(0), 0, 0);
    }

    /// @notice The finality gate may only be invoked by the InteropHandler.
    function test_requireFlowFinalized_revertsWhen_callerNotInteropHandler() public {
        address notInteropHandler = makeAddr("notInteropHandler");
        AtomicFinalityProof memory finality;
        vm.prank(notInteropHandler);
        vm.expectRevert(abi.encodeWithSelector(ManagerNotInteropHandler.selector, notInteropHandler));
        manager.requireFlowFinalized(bytes32(0), finality);
    }
}
