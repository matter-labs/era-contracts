// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {ImtProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {InvalidMessageRoot} from "contracts/common/L1ContractErrors.sol";
import {ProofImtRootInclusionFailed} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {L2_MESSAGE_VERIFICATION_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

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

/// @notice The FULL atomic finality pipeline with NOTHING mocked in any of the four settlement steps:
///
///   1. Include the batch root into the shared one — a real {L1MessageRoot.addChainBatchRootV32}
///      aggregates the chain batch root (built from the real commitment tree's IMT root) into the
///      settlement layer's shared tree.
///   2. Import it — the real aggregated root is imported into the real {L2InteropRootStorage} through
///      the production bootloader entry point.
///   3. Run import verification on L1 — the real {ExecutorFacet._verifyDependencyInteropRoots} checks
///      the imported `(block, root, timestamp)` tuple against the MessageRoot's `historicalRoot`.
///   4. Verify against the imported root — the real {L2MessageVerification} authenticates a settlement
///      proof, whose sibling paths are read from the LIVE MessageRoot trees (chain tree + shared
///      tree), against the imported root, and {AtomicInteropProof} accepts the leg.
///
/// Every earlier atomic proof test either mocks the verifier or hand-computes the aggregation root and
/// seeds it; here the aggregation, the import, the L1 import-verification, and the proof verification
/// all execute against real contracts, and the proof is built from the real trees' own paths — so a
/// divergence between how MessageRoot aggregates and how the proof/verifier reconstructs would be
/// caught. Only bridgehub ACL and the source chain's genesis getters are stubbed (neither is one of the
/// four steps).
contract AtomicInteropProofPipelineTest is AtomicInteropProofBuilder {
    /// @dev The settlement layer (L1) — the chain the aggregation and import-verification run on, and
    /// the flow's `settlementLayerChainId`.
    uint256 internal constant SL_CHAIN_ID = 1;
    /// @dev The source L2 whose batch carries the atomic commitment.
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    /// @dev First real batch (batch 0 is the genesis leaf seeded at registration).
    uint256 internal constant BATCH_N = 1;
    /// @dev SL block the shared root is aggregated in (the `historicalRoot` / interop-root key).
    uint256 internal constant SL_BLOCK = 100;
    /// @dev Batch inclusion time; <= DEADLINE so the leg is in time.
    uint256 internal constant BATCH_TS = 500;

    L1MessageRoot internal messageRoot;
    AtomicPipelineExecutorHarness internal executor;
    address internal bridgehub = makeAddr("bridgehub");
    address internal chainSender = makeAddr("sourceChainSender");
    address internal chainAssetHandler = makeAddr("chainAssetHandler");

    uint256 internal committedValue;
    uint256 internal committedIndex;

    function setUp() public {
        // Aggregation, import-verification and the verifier's own SL-own-entry leaf all read
        // `block.chainid` as the settlement layer, so pin it before deploying anything.
        vm.chainId(SL_CHAIN_ID);
        vm.roll(SL_BLOCK);
        vm.warp(BATCH_TS);

        _setUpAtomicFixtures(); // real commitment tree + real L2InteropRootStorage (no verifier mock)
        deployCodeTo("L2MessageVerification.sol:L2MessageVerification", L2_MESSAGE_VERIFICATION_ADDR);

        committedValue = _commitValue(keccak256("flowA"), keccak256("bundleA"));
        committedIndex = _insertCommit(committedValue);

        _deployRealMessageRoot();
        _registerSourceChainWithGenesis();
    }

    function _deployRealMessageRoot() internal {
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(new uint256[](0))
        );
        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(bridgehub, 1, chainAssetHandler)),
                    address(uint160(1)),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );
        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.messageRoot.selector), abi.encode(messageRoot));
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, SOURCE_CHAIN_ID),
            abi.encode(chainSender)
        );

        executor = new AtomicPipelineExecutorHarness();
        executor.setBridgehub(bridgehub);
    }

    /// @dev Registers the source chain and seeds its genesis (batch 0) leaf — the two steps
    /// `createNewChain` performs — so the chain tree and shared tree hold real entries. Only the
    /// chain's genesis getters are stubbed (not part of the four steps).
    function _registerSourceChainWithGenesis() internal {
        vm.mockCall(chainSender, abi.encodeWithSelector(IGetters.getZKsyncOS.selector), abi.encode(true));
        vm.mockCall(
            chainSender,
            abi.encodeWithSelector(IGetters.l2LogsRootHash.selector, uint256(0)),
            abi.encode(ChainBatchRootTree.genesisChainBatchRoot())
        );
        vm.prank(bridgehub);
        messageRoot.addNewChain(SOURCE_CHAIN_ID, 0);
        vm.prank(bridgehub);
        messageRoot.seedGenesisRoot(SOURCE_CHAIN_ID);
    }

    /// @dev Step 1 for real: builds the chain batch root from the live IMT end root and aggregates it
    /// through the real MessageRoot, returning what the later steps need.
    function _aggregate()
        internal
        returns (bytes32 imtEnd, bytes32 imtBegin, bytes32 genesisChainLeaf, bytes32 sharedRoot, uint256 rootTimestamp)
    {
        imtEnd = tree.root();
        imtBegin = ChainBatchRootTree.EMPTY_IMT_ROOT;
        bytes32 chainBatchRoot = ChainBatchRootTree.compute(bytes32(0), bytes32(0), imtBegin, imtEnd);

        // The genesis (batch 0) chain-tree leaf, captured before the batch push (single-leaf chain root).
        genesisChainLeaf = messageRoot.getChainRoot(SOURCE_CHAIN_ID);

        vm.prank(chainSender);
        messageRoot.addChainBatchRootV32(SOURCE_CHAIN_ID, BATCH_N, chainBatchRoot);

        sharedRoot = messageRoot.getAggregatedRoot();
        rootTimestamp = messageRoot.historicalRoot(SL_BLOCK).timestamp;
        assertEq(
            messageRoot.historicalRoot(SL_BLOCK).root,
            sharedRoot,
            "historical root must match the aggregated root"
        );
    }

    function _depRoots(bytes32 _root, uint256 _timestamp) internal pure returns (InteropRoot[] memory deps) {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = _root;
        deps = new InteropRoot[](1);
        deps[0] = InteropRoot({
            chainId: SL_CHAIN_ID,
            blockOrBatchNumber: SL_BLOCK,
            timestamp: _timestamp,
            sides: sides
        });
    }

    function test_fullPipeline_realAggregationImportVerifyAndProof() public {
        // ---- Step 1: include the batch root into the shared one (real aggregation) ----
        (
            bytes32 imtEnd,
            bytes32 imtBegin,
            bytes32 genesisChainLeaf,
            bytes32 sharedRoot,
            uint256 rootTimestamp
        ) = _aggregate();

        // ---- Step 2: import the aggregated root (real bootloader entry point) ----
        _seedSettlementLayerInteropRootWithValue(SL_CHAIN_ID, SL_BLOCK, rootTimestamp, sharedRoot);

        // ---- Step 3: run import verification on L1 (real Executor dependency-root check) ----
        // Reverts if the imported (root, timestamp) does not match the MessageRoot's historicalRoot.
        executor.verifyDependencyInteropRoots(_depRoots(sharedRoot, rootTimestamp));

        // ---- Step 4: verify the leg against the imported root (real verifier, real-tree paths) ----
        ImtProof memory proof = _buildProofFromLiveTrees(imtEnd, imtBegin, genesisChainLeaf);
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SL_CHAIN_ID);
    }

    /// @notice Step 3 is load-bearing: the real L1 import-verification rejects an imported root that does
    /// not match the MessageRoot's `historicalRoot` (a chain importing a forged SL root is caught).
    function test_fullPipeline_step3_RevertWhen_importedRootDoesNotMatchHistorical() public {
        (, , , bytes32 sharedRoot, uint256 rootTimestamp) = _aggregate();
        bytes32 wrongRoot = keccak256("not the aggregated root");

        vm.expectRevert(abi.encodeWithSelector(InvalidMessageRoot.selector, sharedRoot, wrongRoot));
        executor.verifyDependencyInteropRoots(_depRoots(wrongRoot, rootTimestamp));
    }

    /// @notice Step 4 is load-bearing: with the genuine root imported, a tampered shared-tree sibling
    /// makes the real verifier reconstruct a different root than the imported one, so the leg is
    /// rejected — proving the proof actually authenticates against the real aggregation, not by
    /// construction.
    function test_fullPipeline_step4_RevertWhen_proofSiblingTampered() public {
        (
            bytes32 imtEnd,
            bytes32 imtBegin,
            bytes32 genesisChainLeaf,
            bytes32 sharedRoot,
            uint256 rootTimestamp
        ) = _aggregate();
        _seedSettlementLayerInteropRootWithValue(SL_CHAIN_ID, SL_BLOCK, rootTimestamp, sharedRoot);

        ImtProof memory proof = _buildProofFromLiveTrees(imtEnd, imtBegin, genesisChainLeaf);
        // Flip one bit of the last (shared-tree) proof word.
        uint256 last = proof.settlementProof.length - 1;
        proof.settlementProof[last] = bytes32(uint256(proof.settlementProof[last]) ^ 1);

        vm.expectRevert(abi.encodeWithSelector(ProofImtRootInclusionFailed.selector, SOURCE_CHAIN_ID, BATCH_N, imtEnd));
        proofLib.verifyInclusion(proof, committedValue, DEADLINE, SL_CHAIN_ID);
    }

    /// @dev Assembles the settlement proof from the LIVE MessageRoot trees: the chain-tree sibling is
    /// the captured genesis leaf (batch 1 is the right child of the 2-leaf chain tree), and the
    /// shared-tree path + index come straight from `getMerklePathForChain` / `chainIndex`. The verifier
    /// reconstructs both hops and must land on the imported shared root.
    function _buildProofFromLiveTrees(
        bytes32 _imtEnd,
        bytes32 _imtBegin,
        bytes32 _genesisChainLeaf
    ) internal view returns (ImtProof memory) {
        // hop-1 top tree: chain-batch-root leaf 3 (END) siblings, reproducing ChainBatchRootTree.compute.
        bytes32[] memory topSiblings = new bytes32[](ChainBatchRootTree.TREE_DEPTH);
        topSiblings[0] = _imtBegin;
        topSiblings[1] = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        topSiblings[2] = ChainBatchRootTree.RESERVED_SUBTREE_NODE;

        // hop-1 chain tree: batch 1 is the right child; its left sibling is the genesis (batch 0) leaf.
        bytes32[] memory chainSiblings = new bytes32[](1);
        chainSiblings[0] = _genesisChainLeaf;
        uint256 chainMask = 1;

        // hop-2 shared tree: real path + real leaf index (used as the reconstruction mask).
        bytes32[] memory sharedSiblings = messageRoot.getMerklePathForChain(SOURCE_CHAIN_ID);
        uint256 sharedMask = messageRoot.chainIndex(SOURCE_CHAIN_ID);

        bytes32[] memory settlementProof = _assembleSettlementProof(
            topSiblings,
            chainSiblings,
            chainMask,
            sharedSiblings,
            sharedMask
        );

        return
            ImtProof({
                sourceChainId: SOURCE_CHAIN_ID,
                batchNumber: BATCH_N,
                chainImtRoot: _imtEnd,
                provesAgainstBeginRoot: false,
                settlementProof: settlementProof,
                leaf: tree.leafAt(committedIndex),
                imtLeafIndex: committedIndex,
                imtProof: tree.merklePath(committedIndex)
            });
    }

    /// @dev Lays out the two-hop proof words (see {MessageHashing._getProofData}):
    /// hop1 [meta1][3 top siblings][batchTs][chainMask][chain siblings][slPacked][slChainId]
    /// hop2 [meta2(final)][shared siblings].
    function _assembleSettlementProof(
        bytes32[] memory _topSiblings,
        bytes32[] memory _chainSiblings,
        uint256 _chainMask,
        bytes32[] memory _sharedSiblings,
        uint256 _sharedMask
    ) internal pure returns (bytes32[] memory proof) {
        uint256 topLen = ChainBatchRootTree.TREE_DEPTH;
        uint256 nChain = _chainSiblings.length;
        uint256 nShared = _sharedSiblings.length;
        // meta1(1) + top(topLen) + batchTs(1) + chainMask(1) + chain siblings(nChain) + slPacked(1)
        // + slChainId(1) + meta2(1) + shared siblings(nShared)
        proof = new bytes32[](topLen + nChain + nShared + 6);
        uint256 p = 0;
        proof[p++] = _composeMetadata({_logLeafProofLen: topLen, _batchLeafProofLen: nChain, _finalProofNode: false});
        for (uint256 i = 0; i < topLen; ++i) {
            proof[p++] = _topSiblings[i];
        }
        proof[p++] = bytes32(BATCH_TS);
        proof[p++] = bytes32(_chainMask);
        for (uint256 i = 0; i < nChain; ++i) {
            proof[p++] = _chainSiblings[i];
        }
        proof[p++] = bytes32((SL_BLOCK << 128) | _sharedMask); // slPackedInfo
        proof[p++] = bytes32(SL_CHAIN_ID);
        proof[p++] = _composeMetadata({_logLeafProofLen: nShared, _batchLeafProofLen: 0, _finalProofNode: true});
        for (uint256 i = 0; i < nShared; ++i) {
            proof[p++] = _sharedSiblings[i];
        }
    }
}
