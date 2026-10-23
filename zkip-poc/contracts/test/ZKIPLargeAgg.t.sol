// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {ZKIPBase} from "./helpers/ZKIPBase.sol";
import {ZKIPLiteRegistry, IHonkVerifier} from "../src/ZKIPLiteRegistry.sol";
import {ChainSim} from "../src/mocks/ChainSim.sol";
import {BadAggregate, ImtContinuity, OnlyOwner, SlotInputsMismatch, UnapprovedCircuit} from "../src/ZKIPLiteErrors.sol";
import {AGGREGATED_LARGE_SLOTS, AGGREGATED_SMALL_SLOTS} from "../src/ZKIPLiteConfig.sol";
import {
    FOURTH_ZKIP_CHAIN_ID,
    LARGE_WINDOW_BATCHES_PER_CHAIN,
    TRANSACTION_BASE_GAS,
    ZERO_BYTE_GAS,
    NONZERO_BYTE_GAS
} from "./helpers/ZKIPTestConfig.sol";

contract ZKIPLargeAggE2ETest is ZKIPBase {
    ChainSim internal simD;

    function setUp() public override {
        super.setUp();
        bytes32 emptyState = bytes32(vm.ffi(_prover("init-root")));
        reg.enableChain(C, address(simC), emptyState);
        simD = new ChainSim(FOURTH_ZKIP_CHAIN_ID, reg, mroot);
        mroot.addChain(FOURTH_ZKIP_CHAIN_ID, address(simD));
        reg.enableChain(FOURTH_ZKIP_CHAIN_ID, address(simD), emptyState);
        stateFile[C] = "-";
        stateFile[FOURTH_ZKIP_CHAIN_ID] = "-";
        caps.deposit(C, usdcId, 100e6);
        caps.deposit(FOURTH_ZKIP_CHAIN_ID, eurcId, 50e6);
        reg.setAggregation16(
            IHonkVerifier(deployCode("Agg16Verifier.sol:HonkVerifier")),
            bytes32(vm.ffi(_prover("agg4-vk-commit")))
        );
    }

    function test_agg16FourChainsAgainstFourSeparateWindows() public {
        Inner[] memory statements = _proveFullWindow();
        ZKIPLiteRegistry.AggregatedSubmission[] memory small = new ZKIPLiteRegistry.AggregatedSubmission[](
            AGGREGATED_SMALL_SLOTS
        );
        for (uint256 group = 0; group < AGGREGATED_SMALL_SLOTS; ++group) {
            Inner[] memory subset = new Inner[](AGGREGATED_SMALL_SLOTS);
            for (uint256 j = 0; j < AGGREGATED_SMALL_SLOTS; ++j) {
                subset[j] = statements[group * AGGREGATED_SMALL_SLOTS + j];
            }
            (small[group], ) = _aggregate(subset, string.concat("large_baseline_", vm.toString(group)));
        }
        uint256 snapshot = vm.snapshotState();
        uint256 separateGas;
        for (uint256 group = 0; group < AGGREGATED_SMALL_SLOTS; ++group) {
            separateGas += _measureWindow(small[group], string.concat("large_baseline_", vm.toString(group)));
        }
        _assertFullWindowState(statements);
        assertTrue(vm.revertToState(snapshot));
        (ZKIPLiteRegistry.AggregatedSubmission memory large, bytes memory included) = _aggregate(
            statements,
            "large_full_16"
        );
        assertEq(included.length, AGGREGATED_LARGE_SLOTS);
        for (uint256 i = 0; i < included.length; ++i) {
            assertEq(uint8(included[i]), 1);
        }
        assertEq(large.publicInputs.length, 1 + AGGREGATED_LARGE_SLOTS * 2);
        assertEq(large.vkCommitments.length, AGGREGATED_LARGE_SLOTS);

        bytes32 childKey = large.publicInputs[0];
        large.publicInputs[0] = bytes32(uint256(childKey) ^ 1);
        vm.expectRevert(BadAggregate.selector);
        reg.submitAggregated(large);
        large.publicInputs[0] = childKey;
        bytes32 lastDigest = large.publicInputs[large.publicInputs.length - 1];
        large.publicInputs[large.publicInputs.length - 1] = bytes32(uint256(lastDigest) ^ 1);
        vm.expectRevert();
        reg.submitAggregated(large);
        large.publicInputs[large.publicInputs.length - 1] = lastDigest;

        snapshot = vm.snapshotState();
        large.vkCommitments[AGGREGATED_LARGE_SLOTS - 1] = aggVkCommitments[1];
        for (uint256 i = 0; i < AGGREGATED_LARGE_SLOTS - 1; ++i) {
            _expectDebit(statements[i]);
        }
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.SlotSkipped(
            AGGREGATED_LARGE_SLOTS - 1,
            SLOT_DEBIT,
            abi.encodeWithSelector(SlotInputsMismatch.selector)
        );
        reg.submitAggregated(large);
        assertEq(reg.provenBatch(FOURTH_ZKIP_CHAIN_ID, LARGE_WINDOW_BATCHES_PER_CHAIN), bytes32(0));
        (, bytes32 rootD, uint256 countD, ) = _chainState(FOURTH_ZKIP_CHAIN_ID);
        assertEq(rootD, statements[AGGREGATED_LARGE_SLOTS - 1].debit.cbr.imtBegin);
        assertEq(countD, LARGE_WINDOW_BATCHES_PER_CHAIN);
        assertTrue(vm.revertToState(snapshot));
        large.vkCommitments[AGGREGATED_LARGE_SLOTS - 1] = aggVkCommitments[0];

        // A prior four-slot submission can become stale while later batches in the wrapper still apply.
        snapshot = vm.snapshotState();
        reg.submitAggregated(small[0]);
        for (uint256 i = 0; i < AGGREGATED_SMALL_SLOTS; ++i) {
            vm.expectEmit(address(reg));
            emit ZKIPLiteRegistry.SlotSkipped(
                i,
                SLOT_DEBIT,
                abi.encodeWithSelector(
                    ImtContinuity.selector,
                    statements[i].debit.cbr.imtEnd,
                    statements[i].debit.cbr.imtBegin
                )
            );
        }
        for (uint256 i = AGGREGATED_SMALL_SLOTS; i < statements.length; ++i) {
            _expectDebit(statements[i]);
        }
        reg.submitAggregated(large);
        _assertFullWindowState(statements);
        assertTrue(vm.revertToState(snapshot));

        _approveAggregation(false);
        for (uint256 i = 0; i < statements.length; ++i) {
            vm.expectEmit(address(reg));
            emit ZKIPLiteRegistry.SlotSkipped(
                i,
                SLOT_DEBIT,
                abi.encodeWithSelector(UnapprovedCircuit.selector, aggVkCommitments[0])
            );
        }
        reg.submitAggregated(large);
        assertEq(reg.provenBatch(A, 1), bytes32(0));
        assertEq(caps.cap(A, usdcId), 100e6);
        assertEq(caps.cap(B, eurcId), 50e6);
        assertEq(caps.cap(C, usdcId), 100e6);
        assertEq(caps.cap(FOURTH_ZKIP_CHAIN_ID, eurcId), 50e6);
        _approveAggregation(true);
        for (uint256 i = 0; i < statements.length; ++i) {
            _expectDebit(statements[i]);
        }
        uint256 combinedGas = _measureWindow(large, "large_full_16");
        _assertFullWindowState(statements);
        assertLt(combinedGas, separateGas);
        console2.log("MULTICHAIN separate_windows_gas", separateGas);
        console2.log("MULTICHAIN combined_window_gas", combinedGas);
        console2.log("MULTICHAIN statements", statements.length);
        ChainSim[AGGREGATED_SMALL_SLOTS] memory sims = [simA, simB, simC, simD];
        for (uint256 c = 0; c < sims.length; ++c) {
            for (uint256 batch = 1; batch <= LARGE_WINDOW_BATCHES_PER_CHAIN; ++batch) {
                _execute(sims[c], batch);
            }
            assertEq(sims[c].lastExecuted(), LARGE_WINDOW_BATCHES_PER_CHAIN);
        }
    }

    function _proveFullWindow() internal returns (Inner[] memory statements) {
        statements = new Inner[](AGGREGATED_LARGE_SLOTS);
        for (uint256 batch = 1; batch <= LARGE_WINDOW_BATCHES_PER_CHAIN; ++batch) {
            Swap memory ab = _swap(
                A,
                B,
                10e6,
                5e6,
                uint64(block.timestamp + 1 hours),
                keccak256(abi.encode("large-ab", batch))
            );
            Swap memory cd = _swap(
                C,
                FOURTH_ZKIP_CHAIN_ID,
                10e6,
                5e6,
                uint64(block.timestamp + 1 hours),
                keccak256(abi.encode("large-cd", batch))
            );
            uint256 offset = (batch - 1) * AGGREGATED_SMALL_SLOTS;
            _provePair(statements, offset, ab, simA, simB, batch);
            _provePair(statements, offset + 2, cd, simC, simD, batch);
        }
    }

    function _provePair(
        Inner[] memory _out,
        uint256 _offset,
        Swap memory _swapData,
        ChainSim _left,
        ChainSim _right,
        uint256 _batch
    ) internal {
        _commitLegs(_left, _one(_swapData.cvA));
        _commitLegs(_right, _one(_swapData.cvB));
        _out[_offset] = _proveDebitRec(
            _left,
            _batch,
            _oneB(_swapData.bundleA),
            _oneB(_swapData.pre),
            _one(_swapData.legOfA),
            _batch == 1 ? usdcId : bytes32(0),
            _batch == 1 ? 100e6 : 0,
            string.concat("large_", vm.toString(_left.chainId()), "_", vm.toString(_batch))
        );
        _adopt(_out[_offset]);
        _out[_offset + 1] = _proveDebitRec(
            _right,
            _batch,
            _oneB(_swapData.bundleB),
            _oneB(_swapData.pre),
            _one(1 - _swapData.legOfA),
            _batch == 1 ? eurcId : bytes32(0),
            _batch == 1 ? 50e6 : 0,
            string.concat("large_", vm.toString(_right.chainId()), "_", vm.toString(_batch))
        );
        _adopt(_out[_offset + 1]);
    }

    function _assertFullWindowState(Inner[] memory _statements) internal view {
        for (uint256 i = 0; i < _statements.length; ++i) {
            ZKIPLiteRegistry.DebitSubmission memory sub = _statements[i].debit;
            assertEq(
                reg.provenBatch(sub.chainId, sub.batchNumber),
                keccak256(abi.encode(sub.cbr.imtBegin, sub.cbr.imtEnd))
            );
            if (i >= _statements.length - AGGREGATED_SMALL_SLOTS) {
                (bytes32 root, bytes32 imt, uint256 count, ) = _chainState(sub.chainId);
                assertEq(root, sub.newStateRoot);
                assertEq(imt, sub.cbr.imtEnd);
                assertEq(count, LARGE_WINDOW_BATCHES_PER_CHAIN + 1);
            }
        }
        assertEq(caps.cap(A, usdcId), 0);
        assertEq(caps.cap(B, eurcId), 0);
        assertEq(caps.cap(C, usdcId), 0);
        assertEq(caps.cap(FOURTH_ZKIP_CHAIN_ID, eurcId), 0);
    }

    function _expectDebit(Inner memory _statement) internal {
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.DebitProven(
            _statement.chainId,
            _statement.debit.batchNumber,
            _statement.debit.numLegs,
            _statement.debit.newStateRoot
        );
    }

    function _measureWindow(
        ZKIPLiteRegistry.AggregatedSubmission memory _sub,
        string memory _label
    ) internal returns (uint256 total) {
        uint256 beforeGas = gasleft();
        reg.submitAggregated(_sub);
        uint256 executionGas = beforeGas - gasleft();
        bytes memory data = abi.encodeCall(reg.submitAggregated, (_sub));
        _logGas(string.concat(_label, ": submitAggregated"), executionGas, data);
        total = executionGas + TRANSACTION_BASE_GAS;
        for (uint256 i = 0; i < data.length; ++i) {
            total += data[i] == 0 ? ZERO_BYTE_GAS : NONZERO_BYTE_GAS;
        }
    }

    function test_agg16ConfigurationAndMalformedCounts() public {
        IHonkVerifier verifier = reg.agg16Verifier();
        bytes32 childKey = reg.agg4RecursiveVkCommitment();
        vm.prank(alice);
        vm.expectRevert(OnlyOwner.selector);
        reg.setAggregation16(verifier, childKey);
        ZKIPLiteRegistry.AggregatedSubmission memory sub;
        sub.kinds = new uint8[](AGGREGATED_LARGE_SLOTS);
        sub.publicInputs = new bytes32[](1 + AGGREGATED_LARGE_SLOTS * 2);
        sub.vkCommitments = new bytes32[](AGGREGATED_LARGE_SLOTS);
        sub.publicInputs[0] = reg.agg4RecursiveVkCommitment();
        sub.kinds[AGGREGATED_LARGE_SLOTS - 1] = SLOT_DEBIT;
        vm.expectRevert(BadAggregate.selector);
        reg.submitAggregated(sub);
        sub.kinds[AGGREGATED_LARGE_SLOTS - 1] = 0;
        sub.vkCommitments = new bytes32[](AGGREGATED_SMALL_SLOTS);
        vm.expectRevert(BadAggregate.selector);
        reg.submitAggregated(sub);
    }
}
