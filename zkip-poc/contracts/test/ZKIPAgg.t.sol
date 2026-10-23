// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ZKIPLiteRegistry} from "../src/ZKIPLiteRegistry.sol";
import {
    BadAggregate,
    BatchNotProven,
    ImtContinuity,
    SlotInputsMismatch,
    UnapprovedCircuit
} from "../src/ZKIPLiteErrors.sol";
import {ZKIPBase} from "./helpers/ZKIPBase.sol";

/// @notice End-to-end tests of cross-chain aggregation with real proofs. Each chain proves its own
/// statement as a zero-knowledge noir-recursive UltraHonk proof and hands it to an untrusted aggregator. Per window,
/// the aggregator checks every proof natively, drops failures, and proves one agg_4 proof carrying up to four
/// statements from any chains; L1 verifies only that and applies the slots in order.
contract ZKIPAggE2ETest is ZKIPBase {
    function test_aggMixedDebitSizeClasses() public {
        Swap memory first = _swap(A, B, 10e6, 5e6, uint64(block.timestamp + 1 hours), "mixed-first");
        Swap memory second = _swap(A, B, 20e6, 10e6, uint64(block.timestamp + 1 hours), "mixed-second");
        {
            uint256[] memory values = new uint256[](2);
            (values[0], values[1]) = (first.cvA, second.cvA);
            _commitLegs(simA, values);
        }
        _commitLegs(simB, _one(first.cvB));
        Inner[] memory statements = new Inner[](2);
        {
            bytes[] memory bundles = new bytes[](2);
            bytes[] memory preimages = new bytes[](2);
            uint256[] memory legs = new uint256[](2);
            (bundles[0], bundles[1]) = (first.bundleA, second.bundleA);
            (preimages[0], preimages[1]) = (first.pre, second.pre);
            (legs[0], legs[1]) = (first.legOfA, second.legOfA);
            statements[0] = _proveDebitRec(simA, 1, bundles, preimages, legs, usdcId, 30e6, "mixed_A");
        }
        statements[1] = _proveDebitRec(
            simB,
            1,
            _oneB(first.bundleB),
            _oneB(first.pre),
            _one(1 - first.legOfA),
            eurcId,
            5e6,
            "mixed_B"
        );
        assertEq(statements[0].circuit, "debit_4");
        assertEq(statements[1].circuit, "debit_1");
        (ZKIPLiteRegistry.AggregatedSubmission memory sub, bytes memory included) = _aggregate(statements, "mixed");
        assertEq(included, hex"0101");
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.DebitProven(A, 1, 2, statements[0].debit.newStateRoot);
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.DebitProven(B, 1, 1, statements[1].debit.newStateRoot);
        _submitAggregated(sub, "mixed (debit_4 and debit_1)");
        _adopt(statements[0]);
        _adopt(statements[1]);
        {
            (bytes32 root, bytes32 imt, uint256 count, ) = _chainState(A);
            assertEq(root, statements[0].debit.newStateRoot);
            assertEq(imt, statements[0].debit.cbr.imtEnd);
            assertEq(count, 3);
        }
        {
            (bytes32 root, bytes32 imt, uint256 count, ) = _chainState(B);
            assertEq(root, statements[1].debit.newStateRoot);
            assertEq(imt, statements[1].debit.cbr.imtEnd);
            assertEq(count, 2);
        }
        assertEq(caps.cap(A, usdcId), 70e6);
        assertEq(caps.cap(B, eurcId), 45e6);
        _execute(simA, 1);
        _execute(simB, 1);
        assertEq(simA.lastExecuted(), 1);
        assertEq(simB.lastExecuted(), 1);
    }

    /// @notice The swap of test_swapEndToEnd with one aggregated proof per window: both debits in the first, both
    /// claims in the second.
    function test_aggSwapEndToEnd() public {
        Swap memory s = _swap(A, B, 60e6, 25e6, uint64(block.timestamp + 1 hours), "agg-swap");
        _commitLegs(simA, _one(s.cvA));
        _commitLegs(simB, _one(s.cvB));

        Inner[] memory w1 = new Inner[](2);
        w1[0] = _proveDebitRec(
            simA,
            1,
            _oneB(s.bundleA),
            _oneB(s.pre),
            _one(s.legOfA),
            usdcId,
            100e6,
            "agg_swap_A_debit"
        );
        w1[1] = _proveDebitRec(
            simB,
            1,
            _oneB(s.bundleB),
            _oneB(s.pre),
            _one(1 - s.legOfA),
            eurcId,
            25e6,
            "agg_swap_B_debit"
        );
        (ZKIPLiteRegistry.AggregatedSubmission memory sub, bytes memory inc) = _aggregate(w1, "agg_swap_w1");
        assertEq(inc, hex"0101");

        // The aggregate proof binds both halves of each slot's digest.
        bytes32[] memory original = sub.publicInputs;
        bytes32[] memory tampered = new bytes32[](original.length);
        for (uint256 i = 0; i < original.length; ++i) {
            tampered[i] = original[i];
        }
        tampered[0] = bytes32(uint256(tampered[0]) ^ 1);
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

    function test_aggDigestBindsVkAndSettlementData() public {
        Swap memory swap = _swap(A, B, 60e6, 25e6, uint64(block.timestamp + 1 hours), "digest-binding");
        _commitLegs(simA, _one(swap.cvA));
        _commitLegs(simB, _one(swap.cvB));
        Inner[] memory statements = new Inner[](2);
        statements[0] = _proveDebitRec(
            simA,
            1,
            _oneB(swap.bundleA),
            _oneB(swap.pre),
            _one(swap.legOfA),
            usdcId,
            100e6,
            "digest_A"
        );
        statements[1] = _proveDebitRec(
            simB,
            1,
            _oneB(swap.bundleB),
            _oneB(swap.pre),
            _one(1 - swap.legOfA),
            eurcId,
            25e6,
            "digest_B"
        );
        (ZKIPLiteRegistry.AggregatedSubmission memory sub, ) = _aggregate(statements, "digest");
        bytes32 initialRoot = sub.debits[0].cbr.imtBegin;
        uint256 snapshot = vm.snapshotState();

        // An approved VK of another size cannot be substituted for the one recursively verified.
        sub.vkCommitments[0] = aggVkCommitments[1];
        _expectDigestMismatchWithOtherSlotApplied(sub, initialRoot);
        assertTrue(vm.revertToState(snapshot));
        sub.vkCommitments[0] = aggVkCommitments[0];
        snapshot = vm.snapshotState();

        sub.debits[0].lockAmount = 90e6;
        _expectDigestMismatchWithOtherSlotApplied(sub, initialRoot);
        assertTrue(vm.revertToState(snapshot));
        sub.debits[0].lockAmount = 100e6;
        snapshot = vm.snapshotState();

        bytes32 firstHi = sub.publicInputs[0];
        bytes32 firstLo = sub.publicInputs[1];
        (sub.publicInputs[0], sub.publicInputs[2]) = (sub.publicInputs[2], firstHi);
        (sub.publicInputs[1], sub.publicInputs[3]) = (sub.publicInputs[3], firstLo);
        vm.expectRevert();
        reg.submitAggregated(sub);
        assertTrue(vm.revertToState(snapshot));
    }

    function _expectDigestMismatchWithOtherSlotApplied(
        ZKIPLiteRegistry.AggregatedSubmission memory _sub,
        bytes32 _initialRoot
    ) internal {
        (, bytes32 initialState, , uint256 initialCount, ) = reg.chains(A);
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.SlotSkipped(0, SLOT_DEBIT, abi.encodeWithSelector(SlotInputsMismatch.selector));
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.DebitProven(B, 1, 1, _sub.debits[1].newStateRoot);
        reg.submitAggregated(_sub);
        (, bytes32 state, bytes32 imt, uint256 count, ) = reg.chains(A);
        assertEq(state, initialState);
        assertEq(imt, _initialRoot);
        assertEq(count, initialCount);
        assertEq(reg.provenBatch(A, 1), bytes32(0));
        assertEq(caps.cap(A, usdcId), 100e6);
        (, bytes32 stateB, bytes32 imtB, uint256 countB, ) = reg.chains(B);
        assertEq(stateB, _sub.debits[1].newStateRoot);
        assertEq(imtB, _sub.debits[1].cbr.imtEnd);
        assertEq(countB, 2);
        assertEq(caps.cap(B, eurcId), 25e6);
    }

    function test_aggRejectsMalformedSlotCounts() public {
        ZKIPLiteRegistry.AggregatedSubmission memory sub;
        sub.kinds = new uint8[](4);
        sub.publicInputs = new bytes32[](8);
        sub.kinds[0] = SLOT_DEBIT;
        vm.expectRevert(BadAggregate.selector);
        reg.submitAggregated(sub);

        sub.debits = new ZKIPLiteRegistry.DebitSubmission[](1);
        sub.kinds[0] = 0;
        vm.expectRevert(BadAggregate.selector);
        reg.submitAggregated(sub);

        sub.debits = new ZKIPLiteRegistry.DebitSubmission[](0);
        sub.kinds[0] = 3;
        vm.expectRevert(BadAggregate.selector);
        reg.submitAggregated(sub);

        sub.kinds[0] = 0;
        sub.publicInputs = new bytes32[](7);
        vm.expectRevert(BadAggregate.selector);
        reg.submitAggregated(sub);
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
        w[1] = _proveDebitRec(
            simB,
            1,
            _oneB(s1.bundleB),
            _oneB(s1.pre),
            _one(1 - s1.legOfA),
            eurcId,
            50e6,
            "agg_four_B1"
        );
        _adopt(w[1]);
        w[3] = _proveDebitRec(
            simB,
            2,
            _oneB(s2.bundleB),
            _oneB(s2.pre),
            _one(1 - s2.legOfA),
            bytes32(0),
            0,
            "agg_four_B2"
        );
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
        w[0] = _proveDebitRec(
            simA,
            1,
            _oneB(s.bundleA),
            _oneB(s.pre),
            _one(s.legOfA),
            usdcId,
            100e6,
            "agg_drop_A_debit"
        );
        w[1] = _proveDebitRec(
            simB,
            1,
            _oneB(s.bundleB),
            _oneB(s.pre),
            _one(1 - s.legOfA),
            eurcId,
            25e6,
            "agg_drop_B_debit"
        );

        // B's proof is corrupted on its way to the aggregator.
        string memory bProof = string.concat(w[1].dir, "/proof");
        bytes memory p = vm.readFileBinary(bProof);
        p[200] = p[200] ^ 0x01;
        vm.writeFileBinary(bProof, p);
        (ZKIPLiteRegistry.AggregatedSubmission memory sub, bytes memory inc) = _aggregate(w, "agg_drop");
        assertEq(inc, hex"0100", "the aggregator drops B's invalid proof");

        // With debit_1 revoked, the slot is skipped and nothing changes.
        _approveAggregation(false);
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.SlotSkipped(
            0,
            SLOT_DEBIT,
            abi.encodeWithSelector(UnapprovedCircuit.selector, aggVkCommitments[0])
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
        w[0] = _proveDebitRec(
            simA,
            1,
            _oneB(s.bundleA),
            _oneB(s.pre),
            _one(s.legOfA),
            usdcId,
            100e6,
            "agg_stale_A_debit"
        );
        w[1] = _proveDebitRec(
            simB,
            1,
            _oneB(s.bundleB),
            _oneB(s.pre),
            _one(1 - s.legOfA),
            eurcId,
            25e6,
            "agg_stale_B_debit"
        );
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
