// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ZKIPBase} from "./helpers/ZKIPBase.sol";
import {ZKIPLiteRegistry} from "../src/ZKIPLiteRegistry.sol";
import {BatchNotProven} from "../src/ZKIPLiteErrors.sol";

contract ZKIPInsertionTest is ZKIPBase {
    function test_omittedInteropLegIsUnprovableAndBatchStaysGated() public {
        Swap memory first = _swap(A, B, 10e6, 5e6, uint64(block.timestamp + 1 hours), "first");
        Swap memory second = _swap(A, B, 20e6, 10e6, uint64(block.timestamp + 1 hours), "second");
        uint256[] memory values = new uint256[](2);
        (values[0], values[1]) = (first.cvA, second.cvA);
        _commitLegs(simA, values);

        // The batch end root includes both insertions. Accounting for only the first cannot reach it.
        (bool ok, , ) = _proveDebit(
            A,
            _oneB(first.bundleA),
            _oneB(first.pre),
            _one(first.legOfA),
            usdcId,
            100e6,
            "omitted_leg"
        );
        assertFalse(ok, "omitting a debit must not produce a proof");
        assertEq(caps.cap(A, usdcId), 100e6, "failed proof must not lock funds");
        assertEq(reg.provenBatch(A, 1), bytes32(0));
        (, , uint256 count, ) = _chainState(A);
        assertEq(count, 1, "failed proof must not advance the IMT count");
        vm.expectRevert(abi.encodeWithSelector(BatchNotProven.selector, A, 1));
        simA.execute(1);
        assertEq(simA.lastExecuted(), 0);
    }

    function test_proofBindsNumberOfInsertedLegs() public {
        Swap memory s = _swap(A, B, 10e6, 5e6, uint64(block.timestamp + 1 hours), "count");
        _commitLegs(simA, _one(s.cvA));
        DebitWitness memory w = DebitWitness(A, _oneB(s.bundleA), _oneB(s.pre), _one(s.legOfA), usdcId, 100e6);
        (bool ok, bytes32 newRoot, bytes memory proof) = _proveDebitWith(w, "bound_count", 4, EVM);
        assertTrue(ok);
        ZKIPLiteRegistry.DebitSubmission memory sub = _submission(simA, 1, usdcId, 100e6, newRoot, proof);
        sub.numLegs = 2;
        vm.expectRevert();
        reg.submitDebit(sub);
        assertEq(reg.provenBatch(A, 1), bytes32(0));
        assertEq(caps.cap(A, usdcId), 100e6);
        (, , uint256 count, ) = _chainState(A);
        assertEq(count, 1);

        sub.numLegs = 1;
        // submitDebit selects debit_1 for a one-leg batch; use the matching proof for the accepted path.
        _debitAndSubmit(simA, 1, w.bundles, w.preimages, w.legs, usdcId, 100e6, "bound_count_valid");
        _execute(simA, 1);
        assertEq(simA.lastExecuted(), 1);
    }
}
