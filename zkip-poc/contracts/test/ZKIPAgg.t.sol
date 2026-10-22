// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ZKIPLiteRegistry} from "../src/ZKIPLiteRegistry.sol";
import {BatchNotProven, ImtContinuity, UnapprovedCircuit} from "../src/ZKIPLiteErrors.sol";
import {ZKIPBase} from "./helpers/ZKIPBase.sol";

/// @notice End-to-end tests of cross-chain aggregation with real proofs. Each chain proves its own
/// statement as a zero-knowledge noir-recursive UltraHonk proof and hands it to an untrusted aggregator. Per window,
/// the aggregator checks every proof natively, drops failures, and proves one agg_4 proof carrying up to four
/// statements from any chains; L1 verifies only that and applies the slots in order.
contract ZKIPAggE2ETest is ZKIPBase {
    /// @notice The swap of test_swapEndToEnd with one aggregated proof per window: both debits in the first, both
    /// claims in the second.
    function test_aggSwapEndToEnd() public {
        Swap memory s = _swap(A, B, 60e6, 25e6, uint64(block.timestamp + 1 hours), "agg-swap");
        _commitLegs(simA, _one(s.cvA));
        _commitLegs(simB, _one(s.cvB));

        Inner[] memory w1 = new Inner[](2);
        w1[0] = _proveDebitRec(simA, 1, _oneB(s.bundleA), _oneB(s.pre), _one(s.legOfA), usdcId, 100e6, "agg_swap_A_debit");
        w1[1] = _proveDebitRec(simB, 1, _oneB(s.bundleB), _oneB(s.pre), _one(1 - s.legOfA), eurcId, 25e6, "agg_swap_B_debit");
        (ZKIPLiteRegistry.AggregatedSubmission memory sub, bytes memory inc) = _aggregate(w1, "agg_swap_w1");
        assertEq(inc, hex"0101");

        // The aggregated proof binds every slot's statement: a different lock amount for A doesn't verify.
        bytes32[] memory original = sub.publicInputs;
        bytes32[] memory tampered = new bytes32[](original.length);
        for (uint256 i = 0; i < original.length; ++i) {
            tampered[i] = original[i];
        }
        tampered[15] = bytes32(uint256(90e6)); // slot 0 (A's debit_4): input 15 is the lock amount
        sub.publicInputs = tampered;
        vm.expectRevert();
        reg.submitAggregated(sub);
        sub.publicInputs = original;

        _submitAggregated(sub, "agg_swap_w1 (2 debits)");
        _adopt(w1[0]);
        _adopt(w1[1]);
        assertEq(caps.cap(A, usdcId), 0, "A locked its whole USDC cap");
        assertEq(caps.cap(B, eurcId), 25e6);
        _execute(simA, 1);
        _execute(simB, 1);

        Inner[] memory w2 = new Inner[](2);
        w2[0] = _proveClaimRec(B, _credits(s, s.bundleA, s.legOfA), usdcId, 60e6, "agg_swap_B_claim");
        w2[1] = _proveClaimRec(A, _credits(s, s.bundleB, 1 - s.legOfA), eurcId, 25e6, "agg_swap_A_claim");
        (sub, inc) = _aggregate(w2, "agg_swap_w2");
        assertEq(inc, hex"0101");
        _submitAggregated(sub, "agg_swap_w2 (2 claims)");
        _adopt(w2[0]);
        _adopt(w2[1]);
        assertEq(caps.cap(B, usdcId), 60e6, "B can withdraw what it received");
        assertEq(caps.cap(A, eurcId), 25e6);
        caps.withdraw(B, usdcId, 60e6);
    }

    /// @notice A full window: four statements from two chains, two batches each, in one proof. Slots apply in order,
    /// so a chain's second batch builds on its first within the same transaction.
    function test_aggFourSlotsFromTwoChains() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);
        Swap memory s1 = _swap(A, B, 10e6, 5e6, deadline, "agg-four-1");
        Swap memory s2 = _swap(A, B, 20e6, 10e6, deadline, "agg-four-2");
        _commitLegs(simA, _one(s1.cvA));
        _commitLegs(simA, _one(s2.cvA));
        _commitLegs(simB, _one(s1.cvB));
        _commitLegs(simB, _one(s2.cvB));

        Inner[] memory w = new Inner[](4);
        w[0] = _proveDebitRec(simA, 1, _oneB(s1.bundleA), _oneB(s1.pre), _one(s1.legOfA), usdcId, 100e6, "agg_four_A1");
        _adopt(w[0]); // the chain proves its next batch on top of the state it just proved
        w[2] = _proveDebitRec(simA, 2, _oneB(s2.bundleA), _oneB(s2.pre), _one(s2.legOfA), bytes32(0), 0, "agg_four_A2");
        w[1] = _proveDebitRec(simB, 1, _oneB(s1.bundleB), _oneB(s1.pre), _one(1 - s1.legOfA), eurcId, 50e6, "agg_four_B1");
        _adopt(w[1]);
        w[3] = _proveDebitRec(simB, 2, _oneB(s2.bundleB), _oneB(s2.pre), _one(1 - s2.legOfA), bytes32(0), 0, "agg_four_B2");
        (ZKIPLiteRegistry.AggregatedSubmission memory sub, bytes memory inc) = _aggregate(w, "agg_four");
        assertEq(inc, hex"01010101");

        _submitAggregated(sub, "agg_four (4 debits)");
        for (uint256 b = 1; b <= 2; ++b) {
            _execute(simA, b);
            _execute(simB, b);
        }
        assertEq(simA.lastExecuted(), 2);
        assertEq(simB.lastExecuted(), 2);
    }

    /// @notice Optional inclusion: the aggregator drops a proof that fails native verification and aggregates the
    /// rest. The dropped chain is only delayed: it can prove directly (or in the next window). L1 applies a slot
    /// only if its VK commitment is an approved circuit of its kind.
    function test_aggDropsInvalidProofAndChecksCircuits() public {
        Swap memory s = _swap(A, B, 60e6, 25e6, uint64(block.timestamp + 1 hours), "agg-drop");
        _commitLegs(simA, _one(s.cvA));
        _commitLegs(simB, _one(s.cvB));
        Inner[] memory w = new Inner[](2);
        w[0] = _proveDebitRec(simA, 1, _oneB(s.bundleA), _oneB(s.pre), _one(s.legOfA), usdcId, 100e6, "agg_drop_A_debit");
        w[1] = _proveDebitRec(simB, 1, _oneB(s.bundleB), _oneB(s.pre), _one(1 - s.legOfA), eurcId, 25e6, "agg_drop_B_debit");

        // B's proof is corrupted on its way to the aggregator.
        string memory bProof = string.concat(w[1].dir, "/proof");
        bytes memory p = vm.readFileBinary(bProof);
        p[200] = p[200] ^ 0x01;
        vm.writeFileBinary(bProof, p);
        (ZKIPLiteRegistry.AggregatedSubmission memory sub, bytes memory inc) = _aggregate(w, "agg_drop");
        assertEq(inc, hex"0100", "the aggregator drops B's invalid proof");

        // With debit_4 revoked, the slot is skipped and nothing changes.
        _approveAggregation(false);
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.SlotSkipped(
            0, SLOT_DEBIT, abi.encodeWithSelector(UnapprovedCircuit.selector, aggVkCommitments[0])
        );
        reg.submitAggregated(sub);
        assertEq(reg.provenBatch(A, 1), bytes32(0));

        _approveAggregation(true);
        _submitAggregated(sub, "agg_drop (1 debit)");
        _adopt(w[0]);
        _execute(simA, 1);

        // B's batch stays gated until B proves it, here directly.
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(BatchNotProven.selector, B, 1));
        simB.execute(1);
        _debitAndSubmit(simB, 1, _oneB(s.bundleB), _oneB(s.pre), _one(1 - s.legOfA), eurcId, 25e6, "agg_drop_B_direct");
        _execute(simB, 1);
    }

    /// @notice A slot that is stale when the aggregated proof lands (here: A proved the same batch directly
    /// meanwhile) is skipped, and the other slots still apply. Nothing applies twice.
    function test_aggStaleSlotIsSkipped() public {
        Swap memory s = _swap(A, B, 60e6, 25e6, uint64(block.timestamp + 1 hours), "agg-stale");
        _commitLegs(simA, _one(s.cvA));
        _commitLegs(simB, _one(s.cvB));
        Inner[] memory w = new Inner[](2);
        w[0] = _proveDebitRec(simA, 1, _oneB(s.bundleA), _oneB(s.pre), _one(s.legOfA), usdcId, 100e6, "agg_stale_A_debit");
        w[1] = _proveDebitRec(simB, 1, _oneB(s.bundleB), _oneB(s.pre), _one(1 - s.legOfA), eurcId, 25e6, "agg_stale_B_debit");
        (ZKIPLiteRegistry.AggregatedSubmission memory sub, bytes memory inc) = _aggregate(w, "agg_stale");
        assertEq(inc, hex"0101");

        _debitAndSubmit(simA, 1, _oneB(s.bundleA), _oneB(s.pre), _one(s.legOfA), usdcId, 100e6, "agg_stale_A_direct");
        (, bytes32 provenImtRoot, , ) = _chainState(A);
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.SlotSkipped(
            0,
            SLOT_DEBIT,
            abi.encodeWithSelector(ImtContinuity.selector, provenImtRoot, w[0].debit.cbr.imtBegin)
        );
        _submitAggregated(sub, "agg_stale (1 applied, 1 skipped)");
        _adopt(w[1]);
        _execute(simA, 1);
        _execute(simB, 1);
        assertEq(caps.cap(A, usdcId), 0, "A's lock applied once");
        assertEq(caps.cap(B, eurcId), 25e6);
    }
}
