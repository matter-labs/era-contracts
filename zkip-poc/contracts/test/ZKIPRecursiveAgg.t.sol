// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {ZKIPBase} from "./helpers/ZKIPBase.sol";
import {ZKIPLiteRegistry, IHonkVerifier} from "../src/ZKIPLiteRegistry.sol";
import {ChainSim} from "../src/mocks/ChainSim.sol";
import {BadAggregate, OnlyOwner, UnapprovedCircuit} from "../src/ZKIPLiteErrors.sol";
import {RECURSIVE_AGGREGATION_INPUTS, AGGREGATED_SMALL_SLOTS} from "../src/ZKIPLiteConfig.sol";
import {
    FOURTH_ZKIP_CHAIN_ID,
    FIFTH_ZKIP_CHAIN_ID,
    RECURSIVE_TEST_STATEMENTS,
    RECURSIVE_TEST_CHAINS,
    TRANSACTION_BASE_GAS,
    ZERO_BYTE_GAS,
    NONZERO_BYTE_GAS,
    RECURSIVE_FIRST_CHAIN_BATCHES,
    RECURSIVE_OTHER_CHAIN_BATCHES
} from "./helpers/ZKIPTestConfig.sol";

/// @dev Independent per-chain producers feed a global aggregator that reads only their recursive proofs.
contract ZKIPRecursiveAggE2ETest is ZKIPBase {
    ChainSim[RECURSIVE_TEST_CHAINS] internal sims;
    Swap internal firstFifthFlow;

    function setUp() public override {
        super.setUp();
        sims[0] = simA;
        sims[1] = simB;
        sims[2] = simC;
        sims[3] = new ChainSim(FOURTH_ZKIP_CHAIN_ID, reg, mroot);
        sims[4] = new ChainSim(FIFTH_ZKIP_CHAIN_ID, reg, mroot);
        bytes32 emptyState = bytes32(vm.ffi(_prover("init-root")));
        for (uint256 i = 0; i < sims.length; ++i) {
            uint256 chain = sims[i].chainId();
            if (i >= 2) {
                if (i >= 3) mroot.addChain(chain, address(sims[i]));
                reg.enableChain(chain, address(sims[i]), emptyState);
                stateFile[chain] = "-";
            }
            if (i != 0) caps.deposit(chain, usdcId, 100e6);
        }
        (bytes32 baseKey, bytes32 foldKey) = abi.decode(vm.ffi(_prover("recursive-vk-commits")), (bytes32, bytes32));
        reg.setRecursiveAggregation(
            IHonkVerifier(deployCode("AggFinalizeVerifier.sol:HonkVerifier")),
            baseKey,
            foldKey
        );
    }

    function test_recursiveIndependentFiveChainsSeventeenStatements() public {
        assertEq(reg.zkipChainCount(), RECURSIVE_TEST_CHAINS);
        Inner[] memory statements = new Inner[](RECURSIVE_TEST_STATEMENTS);
        string memory nodes;
        uint256 cursor;
        for (uint256 i = 0; i < sims.length; ++i) {
            uint256 batches = i == 0 ? RECURSIVE_FIRST_CHAIN_BATCHES : RECURSIVE_OTHER_CHAIN_BATCHES;
            Inner[] memory local = new Inner[](batches);
            for (uint256 batch = 1; batch <= batches; ++batch) {
                Swap memory flow = _swap(
                    sims[i].chainId(),
                    sims[(i + 1) % sims.length].chainId(),
                    10e6,
                    5e6,
                    uint64(block.timestamp + 1 hours),
                    keccak256(abi.encode("recursive", i, batch))
                );
                if (i == sims.length - 1 && batch == 1) firstFifthFlow = flow;
                _commitLegs(sims[i], _one(flow.cvA));
                local[batch - 1] = _proveDebitRec(
                    sims[i],
                    batch,
                    _oneB(flow.bundleA),
                    _oneB(flow.pre),
                    _one(flow.legOfA),
                    batch == 1 ? usdcId : bytes32(0),
                    batch == 1 ? 100e6 : 0,
                    string.concat("recursive_inner_", vm.toString(i), "_", vm.toString(batch))
                );
                _adopt(local[batch - 1]);
                statements[cursor++] = local[batch - 1];
            }
            string memory nodeDir = _localNode(local, string.concat("recursive_chain_", vm.toString(i)));
            nodes = string.concat(nodes, i == 0 ? "" : ",", '{"dir":"', nodeDir, '"}');
        }
        assertEq(cursor, statements.length);
        ZKIPLiteRegistry.AggregatedSubmission[] memory baseline = new ZKIPLiteRegistry.AggregatedSubmission[](
            (statements.length + AGGREGATED_SMALL_SLOTS - 1) / AGGREGATED_SMALL_SLOTS
        );
        uint256 snapshot = vm.snapshotState();
        uint256 baselineGas;
        for (uint256 i = 0; i < baseline.length; ++i) {
            uint256 count = statements.length - i * AGGREGATED_SMALL_SLOTS;
            if (count > AGGREGATED_SMALL_SLOTS) count = AGGREGATED_SMALL_SLOTS;
            Inner[] memory subset = new Inner[](count);
            for (uint256 j = 0; j < count; ++j) subset[j] = statements[i * AGGREGATED_SMALL_SLOTS + j];
            (baseline[i], ) = _aggregate(subset, string.concat("recursive_baseline_", vm.toString(i)));
            uint256 baselineBeforeGas = gasleft();
            reg.submitAggregated(baseline[i]);
            baselineGas += _gasTotal(
                baselineBeforeGas - gasleft(),
                abi.encodeCall(reg.submitAggregated, (baseline[i])),
                string.concat("recursive_baseline_", vm.toString(i))
            );
        }
        _assertState(statements);
        assertTrue(vm.revertToState(snapshot));
        string memory manifest = string.concat(WORK, "recursive_global.manifest.json");
        vm.writeFile(manifest, string.concat('{"nodes":[', nodes, "]}"));
        string memory outDir = string.concat(WORK, "recursive_global");
        bytes memory included = vm.ffi(_push(_push(_prover("aggregate-recursive"), manifest), outDir));
        assertEq(included, hex"0101010101");
        ZKIPLiteRegistry.RecursiveSubmission memory sub = _recursiveSubmission(statements, outDir);
        assertEq(sub.publicInputs.length, RECURSIVE_AGGREGATION_INPUTS);
        assertEq(uint256(sub.publicInputs[2]), statements.length);
        assertGt(uint256(sub.publicInputs[3]), 1);
        _checkTampering(sub, statements);
        snapshot = vm.snapshotState();
        reg.submitAggregated(baseline[0]);
        reg.submitRecursive(sub); // stale prefix skips while later statements apply
        _assertState(statements);
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
        reg.submitRecursive(sub);
        assertEq(reg.provenBatch(A, 1), bytes32(0));
        assertEq(caps.cap(FIFTH_ZKIP_CHAIN_ID, usdcId), 100e6);
        _approveAggregation(true);
        for (uint256 i = 0; i < statements.length; ++i) {
            vm.expectEmit(address(reg));
            emit ZKIPLiteRegistry.DebitProven(
                statements[i].chainId,
                statements[i].debit.batchNumber,
                1,
                statements[i].debit.newStateRoot
            );
        }
        uint256 beforeGas = gasleft();
        reg.submitRecursive(sub);
        uint256 combinedGas = _gasTotal(
            beforeGas - gasleft(),
            abi.encodeCall(reg.submitRecursive, (sub)),
            "recursive_global"
        );
        _assertState(statements);
        assertLt(combinedGas, baselineGas);
        console2.log("RECURSIVE separate_windows_gas", baselineGas);
        console2.log("RECURSIVE combined_window_gas", combinedGas);
        console2.log("RECURSIVE final_proof_bytes", sub.proof.length);
        console2.log("RECURSIVE public_inputs", sub.publicInputs.length);
        for (uint256 i = 0; i < sims.length; ++i) {
            uint256 batches = i == 0 ? RECURSIVE_FIRST_CHAIN_BATCHES : RECURSIVE_OTHER_CHAIN_BATCHES;
            for (uint256 batch = 1; batch <= batches; ++batch) _execute(sims[i], batch);
            assertEq(sims[i].lastExecuted(), batches);
        }
        _claimFromFifthChain();
    }

    function _localNode(Inner[] memory _statements, string memory _tag) internal returns (string memory outDir) {
        string memory slots;
        for (uint256 i = 0; i < _statements.length; ++i) {
            // Public settlement attachments omit the original proof path: the parent cannot open leaf proofs.
            slots = string.concat(
                slots,
                i == 0 ? "" : ",",
                '{"circuit":"',
                _statements[i].circuit,
                '","dir":"',
                _statements[i].dir,
                '","settlement":{"batch":',
                vm.toString(_statements[i].debit.batchNumber),
                "}}"
            );
        }
        string memory manifest = string.concat(WORK, _tag, ".manifest.json");
        vm.writeFile(manifest, string.concat('{"slots":[', slots, "]}"));
        outDir = string.concat(WORK, _tag);
        bytes memory included = vm.ffi(_push(_push(_prover("aggregate-node"), manifest), outDir));
        assertEq(included.length, _statements.length);
        for (uint256 i = 0; i < included.length; ++i) assertEq(uint8(included[i]), 1);
    }

    function _recursiveSubmission(
        Inner[] memory _statements,
        string memory _outDir
    ) internal view returns (ZKIPLiteRegistry.RecursiveSubmission memory sub) {
        sub.proof = vm.readFileBinary(string.concat(_outDir, "/proof"));
        sub.publicInputs = _readFields(string.concat(_outDir, "/public_inputs"));
        sub.statementDigests = _readFields(string.concat(_outDir, "/statement_digests"));
        sub.vkCommitments = _readFields(string.concat(_outDir, "/vk_commitments"));
        sub.shape = vm.readFileBinary(string.concat(_outDir, "/tree_shape"));
        sub.kinds = new uint8[](_statements.length);
        sub.debits = new ZKIPLiteRegistry.DebitSubmission[](_statements.length);
        for (uint256 i = 0; i < _statements.length; ++i) {
            sub.kinds[i] = SLOT_DEBIT;
            sub.debits[i] = _statements[i].debit;
        }
    }

    function _checkTampering(ZKIPLiteRegistry.RecursiveSubmission memory _sub, Inner[] memory _statements) internal {
        bytes32 field = _sub.publicInputs[0];
        _sub.publicInputs[0] = bytes32(uint256(field) ^ 1);
        vm.expectRevert(BadAggregate.selector);
        reg.submitRecursive(_sub);
        _sub.publicInputs[0] = field;
        field = _sub.statementDigests[_statements.length - 1];
        _sub.statementDigests[_statements.length - 1] = bytes32(uint256(field) ^ 1);
        vm.expectRevert(BadAggregate.selector);
        reg.submitRecursive(_sub);
        _sub.statementDigests[_statements.length - 1] = field;
        bytes1 token = _sub.shape[0];
        _sub.shape[0] = 0x7f;
        vm.expectRevert(BadAggregate.selector);
        reg.submitRecursive(_sub);
        _sub.shape[0] = token;
        uint256 snapshot = vm.snapshotState();
        _sub.vkCommitments[_statements.length - 1] = aggVkCommitments[1];
        reg.submitRecursive(_sub);
        assertEq(reg.provenBatch(FIFTH_ZKIP_CHAIN_ID, 3), bytes32(0));
        (, bytes32 imt, uint256 count, ) = _chainState(FIFTH_ZKIP_CHAIN_ID);
        assertEq(imt, _statements[_statements.length - 1].debit.cbr.imtBegin);
        assertEq(count, 3);
        assertTrue(vm.revertToState(snapshot));
        _sub.vkCommitments[_statements.length - 1] = aggVkCommitments[0];
    }

    function _assertState(Inner[] memory _statements) internal view {
        uint256 cursor;
        for (uint256 i = 0; i < sims.length; ++i) {
            uint256 batches = i == 0 ? RECURSIVE_FIRST_CHAIN_BATCHES : RECURSIVE_OTHER_CHAIN_BATCHES;
            for (uint256 j = 0; j < batches; ++j) {
                ZKIPLiteRegistry.DebitSubmission memory d = _statements[cursor++].debit;
                assertEq(
                    reg.provenBatch(d.chainId, d.batchNumber),
                    keccak256(abi.encode(d.cbr.imtBegin, d.cbr.imtEnd))
                );
            }
            (bytes32 state, bytes32 imt, uint256 count, ) = _chainState(sims[i].chainId());
            assertEq(state, _statements[cursor - 1].debit.newStateRoot);
            assertEq(imt, _statements[cursor - 1].debit.cbr.imtEnd);
            assertEq(count, batches + 1);
            assertEq(caps.cap(sims[i].chainId(), usdcId), 0);
        }
    }

    function _claimFromFifthChain() internal {
        Swap memory flow = firstFifthFlow;
        caps.deposit(A, eurcId, 50e6);
        _commitLegs(simA, _one(flow.cvB));
        Inner memory counterleg = _proveDebitRec(
            simA,
            6,
            _oneB(flow.bundleB),
            _oneB(flow.pre),
            _one(1 - flow.legOfA),
            eurcId,
            50e6,
            "recursive_fifth_counterleg"
        );
        Inner[] memory single = new Inner[](1);
        single[0] = counterleg;
        (ZKIPLiteRegistry.AggregatedSubmission memory agg, ) = _aggregate(single, "recursive_fifth_counterleg_agg");
        reg.submitAggregated(agg);
        _adopt(counterleg);
        _execute(simA, 6);
        Credit[] memory credits = new Credit[](1);
        credits[0] = Credit(flow.bundleA, flow.pre, flow.legOfA, _slotCvs(flow), _slotChains(flow, sims[4], simA));
        (bool ok, bytes32 root, bytes memory proof) = _proveClaim(A, credits, usdcId, 10e6, "recursive_fifth_claim");
        assertTrue(ok);
        vm.expectEmit(address(reg));
        emit ZKIPLiteRegistry.ClaimProven(A, 1, root);
        reg.submitClaim(_claimSubmission(A, 1, usdcId, 10e6, root, proof));
        (bytes32 actual, , , ) = _chainState(A);
        assertEq(actual, root);
        assertEq(caps.cap(A, usdcId), 10e6);
        vm.expectRevert();
        reg.submitClaim(_claimSubmission(A, 1, usdcId, 10e6, root, proof));
    }

    function _gasTotal(
        uint256 _execution,
        bytes memory _data,
        string memory _label
    ) internal pure returns (uint256 total) {
        total = _execution + TRANSACTION_BASE_GAS;
        for (uint256 i = 0; i < _data.length; ++i) total += _data[i] == 0 ? ZERO_BYTE_GAS : NONZERO_BYTE_GAS;
        _logGas(_label, _execution, _data);
    }

    function test_recursiveConfigurationAndMalformedCounts() public {
        IHonkVerifier verifier = reg.recursiveVerifier();
        bytes32 baseKey = reg.recursiveBaseVkCommitment();
        bytes32 foldKey = reg.recursiveFoldVkCommitment();
        vm.prank(alice);
        vm.expectRevert(OnlyOwner.selector);
        reg.setRecursiveAggregation(verifier, baseKey, foldKey);
        ZKIPLiteRegistry.RecursiveSubmission memory sub;
        vm.expectRevert(BadAggregate.selector);
        reg.submitRecursive(sub);
        sub.kinds = new uint8[](1);
        sub.vkCommitments = new bytes32[](1);
        sub.statementDigests = new bytes32[](1);
        sub.publicInputs = new bytes32[](RECURSIVE_AGGREGATION_INPUTS);
        sub.publicInputs[0] = baseKey;
        sub.publicInputs[1] = foldKey;
        sub.publicInputs[2] = bytes32(uint256(1));
        sub.kinds[0] = SLOT_DEBIT;
        vm.expectRevert(BadAggregate.selector);
        reg.submitRecursive(sub);
    }
}
