// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ZKIPLiteRegistry} from "../src/ZKIPLiteRegistry.sol";
import {BatchNotProven, CapExceeded, ImtContinuity, UnknownAnchor} from "../src/ZKIPLiteErrors.sol";
import {ChainSim} from "../src/mocks/ChainSim.sol";
import {ZKIPBase} from "./helpers/ZKIPBase.sol";

/// @notice End-to-end tests of the ZKIP-lite PoC with real UltraHonk proofs, each statement verified on its own
/// (submitDebit / submitClaim). Setup and helpers are in ZKIPBase.
contract ZKIPLiteE2ETest is ZKIPBase {
    // ------------------------------------------------------------------------------------- scenarios

    /// @notice A swaps 60 USDC for B's 25 EURC atomically; both chains prove their debits, then claim the other
    /// leg and unlock it to their public caps, and B withdraws what it received.
    function test_swapEndToEnd() public {
        Swap memory s = _swap(A, B, 60e6, 25e6, uint64(block.timestamp + 1 hours), "swap-1");

        _commitLegs(simA, _one(s.cvA));
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(BatchNotProven.selector, A, 1));
        simA.execute(1);
        _debitAndSubmit(simA, 1, _oneB(s.bundleA), _oneB(s.pre), _one(s.legOfA), usdcId, 100e6, "swap_A_debit");
        assertEq(caps.cap(A, usdcId), 0, "A locked its whole USDC cap");
        _execute(simA, 1);

        _commitLegs(simB, _one(s.cvB));
        _debitAndSubmit(simB, 1, _oneB(s.bundleB), _oneB(s.pre), _one(1 - s.legOfA), eurcId, 25e6, "swap_B_debit");
        assertEq(caps.cap(B, eurcId), 25e6);
        _execute(simB, 1);

        // B credits A's leg (finality of both legs proved in-circuit) and unlocks the 60 USDC to its cap.
        _claimAndSubmit(B, _credits(s, s.bundleA, s.legOfA), usdcId, 60e6, "swap_B_claim");
        assertEq(caps.cap(B, usdcId), 60e6, "B can withdraw what it received");
        caps.withdraw(B, usdcId, 60e6);
        vm.expectRevert(abi.encodeWithSelector(CapExceeded.selector, B, usdcId, 0, 1));
        caps.withdraw(B, usdcId, 1);

        // A credits B's leg and unlocks the 25 EURC.
        _claimAndSubmit(A, _credits(s, s.bundleB, 1 - s.legOfA), eurcId, 25e6, "swap_A_claim");
        assertEq(caps.cap(A, eurcId), 25e6);

        // The same leg can't be credited twice: the consumed set rejects it inside the circuit.
        (bool ok, , ) = _proveClaim(B, _credits(s, s.bundleA, s.legOfA), bytes32(0), 0, "swap_B_double");
        assertFalse(ok, "double credit must be unprovable");
    }

    /// @notice Larger size classes: a batch with three legs (debit_4), then two credits in one claim (claim_2)
    /// and the third in its own claim (claim_1).
    function test_multiLegBatchAndBatchedClaims() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        Swap[3] memory s;
        uint256[] memory cvsA = new uint256[](3);
        uint256[] memory cvsB = new uint256[](3);
        bytes[] memory bundlesA = new bytes[](3);
        bytes[] memory bundlesB = new bytes[](3);
        bytes[] memory pres = new bytes[](3);
        uint256[] memory legsA = new uint256[](3);
        uint256[] memory legsB = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) {
            s[i] = _swap(A, B, (i + 1) * 10e6, (i + 1) * 5e6, deadline, keccak256(abi.encode("multi", i)));
            (cvsA[i], cvsB[i], bundlesA[i], bundlesB[i], pres[i]) = (s[i].cvA, s[i].cvB, s[i].bundleA, s[i].bundleB, s[i].pre);
            (legsA[i], legsB[i]) = (s[i].legOfA, 1 - s[i].legOfA);
        }
        _commitLegs(simA, cvsA);
        _debitAndSubmit(simA, 1, bundlesA, pres, legsA, usdcId, 60e6, "multi_A_debit");
        _execute(simA, 1);
        _commitLegs(simB, cvsB);
        _debitAndSubmit(simB, 1, bundlesB, pres, legsB, eurcId, 30e6, "multi_B_debit");
        _execute(simB, 1);

        Credit[] memory two = new Credit[](2);
        two[0] = _credits(s[0], s[0].bundleA, s[0].legOfA)[0];
        two[1] = _credits(s[1], s[1].bundleA, s[1].legOfA)[0];
        _claimAndSubmit(B, two, usdcId, 30e6, "multi_B_claim2");
        _claimAndSubmit(B, _credits(s[2], s[2].bundleA, s[2].legOfA), usdcId, 30e6, "multi_B_claim1");
        assertEq(caps.cap(B, usdcId), 60e6, "B received 10 + 20 + 30 USDC");
        assertEq(caps.cap(A, usdcId), 40e6, "A kept 40 of its 100 USDC on L1");
    }

    /// @notice A broken chain sends more than its interop balance: no debit proof exists, so the batch never
    /// executes and the leg never becomes provable to anyone.
    function test_overdraftIsUnprovableAndBlocksExecution() public {
        Swap memory s = _swap(A, B, 150e6, 25e6, uint64(block.timestamp + 1 hours), "overdraft");
        _commitLegs(simA, _one(s.cvA));
        (bool ok, , ) = _proveDebit(A, _oneB(s.bundleA), _oneB(s.pre), _one(s.legOfA), usdcId, 100e6, "overdraft_A");
        assertFalse(ok, "debit beyond the locked balance must be unprovable");
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(BatchNotProven.selector, A, 1));
        simA.execute(1);
    }

    /// @notice Variant (c): a batch that appended no legs executes with no ZKIP proof at all.
    function test_batchWithoutLegsNeedsNoProof() public {
        simA.beginBatch();
        simA.endBatch(keccak256("logs"));
        _execute(simA, 1);
        assertEq(simA.lastExecuted(), 1);
    }

    /// @notice Gas of the execute gate for a batch without legs (the common case under variant c).
    function test_gateGasForBatchWithoutLegs() public {
        simA.beginBatch();
        simA.endBatch(keccak256("logs"));
        ZKIPLiteRegistry.ChainBatchRootPreimage memory p = simA.preimage(1);
        vm.prank(address(simA));
        uint256 g = gasleft();
        reg.onExecute(A, 1, p);
        _logGas("onExecute (no legs)", g - gasleft(), abi.encodeCall(reg.onExecute, (A, 1, p)));
    }

    /// @notice Gate gas for a further batch executed in the same transaction (warm registry and chain state).
    function test_gateGasForFurtherBatchInSameTx() public {
        simA.beginBatch();
        simA.endBatch(keccak256("logs1"));
        simA.beginBatch();
        simA.endBatch(keccak256("logs2"));
        ZKIPLiteRegistry.ChainBatchRootPreimage memory p1 = simA.preimage(1);
        ZKIPLiteRegistry.ChainBatchRootPreimage memory p2 = simA.preimage(2);
        vm.startPrank(address(simA));
        reg.onExecute(A, 1, p1);
        uint256 g = gasleft();
        reg.onExecute(A, 2, p2);
        vm.stopPrank();
        _logGas("onExecute (no legs, further batch)", g - gasleft(), abi.encodeCall(reg.onExecute, (A, 2, p2)));
    }

    /// @notice L1 checks IMT continuity: debit proofs must chain over the leg batches in order.
    function test_imtContinuityIsEnforcedOnL1() public {
        Swap memory s1 = _swap(A, B, 10e6, 1e6, uint64(block.timestamp + 1 hours), "c1");
        Swap memory s2 = _swap(A, B, 20e6, 2e6, uint64(block.timestamp + 1 hours), "c2");
        _commitLegs(simA, _one(s1.cvA));
        _commitLegs(simA, _one(s2.cvA));
        ZKIPLiteRegistry.DebitSubmission memory sub = _submission(simA, 2, bytes32(0), 0, bytes32(0), "");
        (, bytes32 provenImtRoot, , ) = _chainState(A);
        vm.expectRevert(
            abi.encodeWithSelector(ImtContinuity.selector, provenImtRoot, sub.cbr.imtBegin)
        );
        reg.submitDebit(sub);
    }

    /// @notice A valid proof submitted with different public data (here: a larger lock) is rejected.
    function test_proofBoundToPublicInputs() public {
        Swap memory s = _swap(A, B, 60e6, 25e6, uint64(block.timestamp + 1 hours), "bound");
        _commitLegs(simA, _one(s.cvA));
        (bool ok, bytes32 newRoot, bytes memory proof) =
            _proveDebit(A, _oneB(s.bundleA), _oneB(s.pre), _one(s.legOfA), usdcId, 100e6, "bound_A");
        assertTrue(ok);
        ZKIPLiteRegistry.DebitSubmission memory sub = _submission(simA, 1, usdcId, 90e6, newRoot, proof);
        vm.expectRevert();
        reg.submitDebit(sub);
    }

    /// @notice The counter-leg settled after the deadline: the flow is not final and can't be credited.
    function test_lateLegCannotBeCredited() public {
        Swap memory s = _swap(A, B, 60e6, 25e6, uint64(block.timestamp + 1 hours), "late");
        _commitLegs(simA, _one(s.cvA));
        _debitAndSubmit(simA, 1, _oneB(s.bundleA), _oneB(s.pre), _one(s.legOfA), usdcId, 100e6, "late_A_debit");
        _execute(simA, 1);
        vm.warp(block.timestamp + 2 hours);
        _commitLegs(simB, _one(s.cvB));
        _debitAndSubmit(simB, 1, _oneB(s.bundleB), _oneB(s.pre), _one(1 - s.legOfA), eurcId, 25e6, "late_B_debit");
        _execute(simB, 1);
        (bool ok, , ) = _proveClaim(B, _credits(s, s.bundleA, s.legOfA), bytes32(0), 0, "late_B_claim");
        assertFalse(ok, "a leg settled after the deadline must not finalize the flow");
    }

    /// @notice A leg from a chain that is not a ZKIP chain can't make a flow final for crediting.
    function test_nonZkipLegSourceCannotBeCredited() public {
        Swap memory s = _swap(A, C, 60e6, 25e6, uint64(block.timestamp + 1 hours), "nonzkip");
        _commitLegs(simA, _one(s.cvA));
        _debitAndSubmit(simA, 1, _oneB(s.bundleA), _oneB(s.pre), _one(s.legOfA), usdcId, 100e6, "nonzkip_A_debit");
        _execute(simA, 1);
        _commitLegs(simC, _one(s.cvB));
        _execute(simC, 1);
        Credit[] memory credits = new Credit[](1);
        credits[0] = Credit(s.bundleB, s.pre, 1 - s.legOfA, _slotCvs(s), _slotChains(s, simA, simC));
        (bool ok, , ) = _proveClaim(A, credits, bytes32(0), 0, "nonzkip_A_claim");
        assertFalse(ok, "credits need every leg source to be a ZKIP chain");
    }

    /// @notice Anchors must be L1 message roots that exist.
    function test_unknownAnchorRejected() public {
        ZKIPLiteRegistry.ClaimSubmission memory c;
        c.chainId = B;
        c.numCredits = 1;
        c.anchorBlocks = [uint256(5), uint256(5)];
        vm.expectRevert(abi.encodeWithSelector(UnknownAnchor.selector, 5));
        reg.submitClaim(c);
    }
}
