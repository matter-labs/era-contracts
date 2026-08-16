// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {ImtProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {InvalidMessageRoot} from "contracts/common/L1ContractErrors.sol";
import {ProofImtRootInclusionFailed} from "contracts/atomic-interop/AtomicInteropErrors.sol";

/// @dev Exposes the real Executor-side dependency-interop-root verification (the "import verification
/// on L1" that runs when an importing batch settles) so it can be driven directly against a real
/// {L1MessageRoot}'s `historicalRoot`.
contract AtomicPipelineExecutorHarness is ExecutorFacet {
    function setBridgehub(address _bridgehub) external {
        s.bridgehub = _bridgehub;
    }

    function verifyDependencyInteropRoots(InteropRoot[] memory _dependencyRoots) external view returns (bytes32) {
        return _verifyDependencyInteropRoots(_dependencyRoots);
    }
}

/// @notice The FULL atomic finality pipeline composed over ONE root: (1) real aggregation
/// ({L1MessageRoot.addChainBatchRootV32}), (2) real import ({L2InteropRootStorage}), (3) real L1
/// import verification ({ExecutorFacet._verifyDependencyInteropRoots} against `historicalRoot`),
/// (4) real proof verification ({L2MessageVerification} + {AtomicInteropProof}). Steps 1/2/4 are the
/// builder's `_real*` machinery; what only this suite adds is step 3 and the composition — a
/// divergence between aggregation, the Executor's check, and proof reconstruction would be caught.
/// Only bridgehub ACL and the source chain's genesis getters are stubbed (neither is one of the
/// four steps).
contract AtomicInteropProofPipelineTest is AtomicInteropProofBuilder {
    /// @dev The settlement layer (L1); the Executor accepts dependency roots for `block.chainid` only.
    uint256 internal constant SL_CHAIN_ID = 1;
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    /// @dev Batch inclusion time; <= DEADLINE so the leg is in time.
    uint256 internal constant BATCH_TS = 500;

    AtomicPipelineExecutorHarness internal executor;

    uint256 internal committedValue;
    uint256 internal committedIndex;

    function setUp() public {
        // The Executor's dependency check and the verifier's SL-own-entry both read `block.chainid`.
        vm.chainId(SL_CHAIN_ID);

        _setUpAtomicFixtures();
        committedValue = _commitValue(keccak256("flowA"), keccak256("bundleA"));
        committedIndex = _insertCommit(committedValue);

        // The Executor harness resolves the MessageRoot through its bridgehub; point it at the
        // builder's real aggregation oracle.
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.messageRoot.selector),
            abi.encode(slMessageRoot)
        );
        executor = new AtomicPipelineExecutorHarness();
        executor.setBridgehub(msgRootBridgehub);
    }

    function _depRoots(
        uint256 _slBlock,
        bytes32 _root,
        uint256 _timestamp
    ) internal pure returns (InteropRoot[] memory deps) {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = _root;
        deps = new InteropRoot[](1);
        deps[0] = InteropRoot({
            chainId: SL_CHAIN_ID,
            blockOrBatchNumber: _slBlock,
            timestamp: _timestamp,
            sides: sides
        });
    }

    function test_fullPipeline_realAggregationImportVerifyAndProof() public {
        // ---- Steps 1 + 2: real aggregation + import (and the live-tree proof for step 4) ----
        ImtProof memory proof = _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, BATCH_TS);
        uint256 slBlock = block.number;
        bytes32 sharedRoot = slMessageRoot.getAggregatedRoot();
        uint256 rootTimestamp = slMessageRoot.historicalRoot(slBlock).timestamp;
        assertEq(
            slMessageRoot.historicalRoot(slBlock).root,
            sharedRoot,
            "historical root must match the aggregated root"
        );

        // ---- Step 3: run import verification on L1 (real Executor dependency-root check) ----
        // The returned rolling hash is what the Executor binds into `_checkBatchData`; pin its exact
        // (chainId, block, timestamp, sides) preimage so a broken binding cannot pass silently.
        bytes32 rollingHash = executor.verifyDependencyInteropRoots(_depRoots(slBlock, sharedRoot, rootTimestamp));
        bytes32[] memory expectedSides = new bytes32[](1);
        expectedSides[0] = sharedRoot;
        assertEq(
            rollingHash,
            keccak256(
                // solhint-disable-next-line func-named-parameters
                abi.encodePacked(bytes32(0), uint256(SL_CHAIN_ID), slBlock, rootTimestamp, expectedSides)
            ),
            "step 3 rolling hash must bind (chainId, block, timestamp, sides)"
        );

        // ---- Step 4: the real verifier accepts the leg against the imported root ----
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SL_CHAIN_ID);
    }

    /// @notice Step 3 is load-bearing: the real L1 import verification rejects an imported root that
    /// does not match the MessageRoot's `historicalRoot`.
    function test_fullPipeline_step3_RevertWhen_importedRootDoesNotMatchHistorical() public {
        _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, BATCH_TS);
        uint256 slBlock = block.number;
        bytes32 sharedRoot = slMessageRoot.getAggregatedRoot();
        uint256 rootTimestamp = slMessageRoot.historicalRoot(slBlock).timestamp;
        bytes32 wrongRoot = keccak256("not the aggregated root");

        vm.expectRevert(abi.encodeWithSelector(InvalidMessageRoot.selector, sharedRoot, wrongRoot));
        executor.verifyDependencyInteropRoots(_depRoots(slBlock, wrongRoot, rootTimestamp));
    }

    /// @notice Step 4 is load-bearing: with the genuine root imported, a tampered shared-tree sibling
    /// makes the real verifier reconstruct a different root than the imported one, so the leg is
    /// rejected — proving the proof authenticates against the real aggregation, not by construction.
    function test_fullPipeline_step4_RevertWhen_proofSiblingTampered() public {
        ImtProof memory proof = _realInclusionProof(SOURCE_CHAIN_ID, committedIndex, BATCH_TS);
        // Flip one bit of the last (shared-tree) proof word.
        uint256 last = proof.settlementProof.length - 1;
        proof.settlementProof[last] = bytes32(uint256(proof.settlementProof[last]) ^ 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProofImtRootInclusionFailed.selector,
                SOURCE_CHAIN_ID,
                proof.batchNumber,
                proof.chainImtRoot
            )
        );
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SL_CHAIN_ID);
    }
}
