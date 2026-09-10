// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicPredeployFixture} from "./AtomicFlowFixtures.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AtomicInteropProof} from "contracts/atomic-interop/libraries/AtomicInteropProof.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {ImtProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IMTLeaf} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {CHAIN_TREE_EMPTY_ENTRY_HASH} from "contracts/core/message-root/IMessageRoot.sol";
import {SUPPORTED_PROOF_METADATA_VERSION} from "contracts/common/Config.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_BOOTLOADER_ADDRESS,
    L2_INTEROP_ROOT_STORAGE_ADDR,
    L2_MESSAGE_VERIFICATION_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_MESSAGE_VERIFICATION} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

error AtomicProofBuilderOnlySupportsFirstPostGenesisBatch(uint256 sourceChainId, uint256 batchNumber);

/// @notice Test-only external re-export of the internal {AtomicInteropProof} library so its
/// `internal`/`view`/`pure` functions can be exercised (and `vm.expectRevert`-ed) from a test.
/// @dev This is NOT a logic mock: every function forwards verbatim to the real library, so the real
/// authentication + clock logic runs. Same pattern as `IndexedMerkleTreeHarness`
/// (IndexedMerkleTree.t.sol) and `AttributesDecoderWrapper` (AttributesDecoder.t.sol).
contract AtomicInteropProofWrapper {
    function commitValue(bytes32 _flowId, bytes32 _bundleHash) external pure returns (uint256) {
        return AtomicInteropProof.commitValue(_flowId, _bundleHash);
    }

    function verifyInclusion(
        ImtProof calldata _proof,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) external view {
        AtomicInteropProof.verifyInclusion(_proof, _commitValue, _deadline, _expectedSlChainId);
    }

    function verifyTimeoutAbsence(
        ImtProof calldata _absence,
        uint256 _commitValue,
        uint64 _deadline,
        uint256 _expectedSlChainId
    ) external view {
        AtomicInteropProof.verifyTimeoutAbsence(_absence, _commitValue, _deadline, _expectedSlChainId);
    }
}

/// @notice Shared fixtures + on-chain proof builders for the {AtomicInteropProof} unit tests.
///
/// Design:
///   - A REAL {L2InteropCommitmentTree} is the IMT oracle: we insert commit values through the real
///     `insert` path and read `root()`/`leafAt`/`merklePath` to assemble genuine inclusion /
///     non-inclusion `ImtProof`s. No second (off-chain) IMT implementation is maintained, so on-chain
///     and off-chain layouts cannot drift.
///   - A REAL {L2InteropRootStorage} is etched at its canonical address and seeded through the
///     production `addSingleInteropRoot` entry point (pranked as the bootloader), so the timeout
///     protocol's settlement-layer interop root `(root, timestamp)` tuples are served by the real storage — no mocked
///     root values.
///   - A REAL {L2MessageVerification} and a REAL {L1MessageRoot} aggregation oracle: the `_real*`
///     builders below aggregate a chain batch root through the production `addChainBatchRootV32`, read
///     the shared-tree path from the live MessageRoot, import the shared root, and authenticate the
///     assembled proof through the real verifier. This is the DEFAULT — happy proofs are fully
///     un-mocked end to end.
///   - The `_real*` builders intentionally cover only a source chain's first post-genesis batch. Their
///     one-sibling chain-tree path is valid only for batch 1; attempting to build a later batch proof
///     fails explicitly with {AtomicProofBuilderOnlySupportsFirstPostGenesisBatch}. Cache a proof or use
///     a distinct source chain when a test needs more than one proof in the same fixture.
///
/// The only mock, and only where a branch cannot otherwise be reached, is
/// `L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared` via {_mockVerifier}: forced to `false` for the
/// handful of negatives that must fail authentication, or to `true` for the branch-isolation cases
/// whose synthetic `settlementProof` blob (a specific depth / mask / cascade / final-node shape) real
/// aggregation cannot produce. Even then it does NOT bypass the `MessageHashing` accessors
/// `AtomicInteropProof` calls directly (`parseProofMetadata` / `readSettlementLayerReference` /
/// `readAggregationHopPath`): the blob is still decoded for real (decoded only, never hashed — all
/// Merkle hashing is the mocked verifier's job, so dummy siblings suffice), keeping the SL-match /
/// clock / last-batch branches live. The cross-chain leaf-inclusion layer itself is covered by
/// L2MessageVerification.t.sol.
///
/// The legacy `_inclusionProof` / `_nonInclusionProof` / `_settlementProof` helpers build such minimal
/// well-formed non-final blobs carrying a caller-chosen `(settlementLayerChainId, slBlock,
/// l1Timestamp)` and batch-leaf path, used only by those stubbed branch-isolation cases.
///
/// Setup additionally stubs read-side WIRING (not proof-path logic): the L2 Bridgehub registry /
/// chain-getter views the real aggregation oracle consults (`_ensureChainRegistered` /
/// `_setUpAtomicFixtures`), so the canonical predeploys resolve without deploying the full bridgehub
/// stack. None of these stubs feeds the Merkle math the proofs authenticate against.
abstract contract AtomicInteropProofBuilder is AtomicPredeployFixture {
    /// @dev The settlement layer every atomic flow in these suites declares (L1).
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1;
    /// @dev The flow deadline all proofs are built against (shared with the tests so the builders
    /// can declare the honest timeout branch for a given batch timestamp).
    uint64 internal constant DEADLINE = 1_000;

    /// @dev The settlement layer every real proof aggregates + imports against (L1 in this release).
    /// Defaults to 1; harnesses whose flows declare a different `settlementLayerChainId` (e.g. the
    /// integration deployment's `L1_CHAIN_ID`) override it so the baked proof word + import key align.
    uint256 internal builderSlChainId = SETTLEMENT_LAYER_CHAIN_ID;

    AtomicInteropProofWrapper internal proofLib;
    L2InteropCommitmentTree internal tree;
    L2InteropRootStorage internal rootStorage;

    // --- Real settlement machinery (aggregation oracle) for the un-mocked proof path ---
    L1MessageRoot internal slMessageRoot;
    address internal msgRootBridgehub = makeAddr("atomicProofBridgehub");
    /// @dev Per-source-chain next batch number (batch 0 is the genesis leaf seeded at registration).
    mapping(uint256 chainId => uint256 nextBatch) internal _nextBatch;
    uint256 internal constant FIRST_POST_GENESIS_BATCH = 1;
    /// @dev Monotonic SL block used as each imported root's key.
    uint256 internal _slBlockCursor = 1_000;

    /// @dev Deploys the wrapper + a fresh commitment tree, etches the real interop-root storage at
    /// its canonical address, seeds the tree, and stands up the REAL settlement machinery — the real
    /// {L2MessageVerification} at its canonical address and a real {L1MessageRoot} aggregation oracle —
    /// so proofs authenticate against genuinely aggregated + imported roots by default. Tests that need
    /// to force a verification failure still call {_mockVerifier}, which overrides the real verifier.
    function _setUpAtomicFixtures() internal {
        proofLib = new AtomicInteropProofWrapper();
        tree = new L2InteropCommitmentTree();
        // Seeds the `{0,0,0}` head leaf at index 0.
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();

        // The timeout protocol reads the root tuple from the canonical address; etch the REAL contract
        // there so tests seed it through the production write path.
        rootStorage = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);
        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);

        // Real cross-chain verifier at its canonical address (no default mock).
        deployCodeTo("L2MessageVerification.sol:L2MessageVerification", L2_MESSAGE_VERIFICATION_ADDR);

        // Real settlement-layer aggregation oracle: produces genuine shared roots + proof paths.
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(makeAddr("atomicProofChainAssetHandler"))
        );
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(new uint256[](0))
        );
        slMessageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(msgRootBridgehub, 1, makeAddr("atomicProofChainAssetHandler"))),
                    address(uint160(1)),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );
    }

    // Real settlement machinery: aggregate a chain batch root, import the shared root, build a proof
    // whose sibling paths come from the live MessageRoot trees. Nothing mocked in steps 1/2/4.

    /// @dev Registers `_sourceChainId` in the MessageRoot and seeds its genesis (batch 0) leaf, once.
    function _ensureChainRegistered(uint256 _sourceChainId) internal {
        if (slMessageRoot.chainRegistered(_sourceChainId)) {
            return;
        }
        address chainSender = address(uint160(uint256(keccak256(abi.encode("chainSender", _sourceChainId)))));
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, _sourceChainId),
            abi.encode(chainSender)
        );
        vm.mockCall(chainSender, abi.encodeWithSelector(IGetters.getZKsyncOS.selector), abi.encode(true));
        vm.mockCall(
            chainSender,
            abi.encodeWithSelector(IGetters.l2LogsRootHash.selector, uint256(0)),
            abi.encode(ChainBatchRootTree.genesisChainBatchRoot())
        );
        vm.prank(msgRootBridgehub);
        slMessageRoot.addNewChain(_sourceChainId, 0);
        vm.prank(msgRootBridgehub);
        slMessageRoot.seedGenesisRoot(_sourceChainId);
        _nextBatch[_sourceChainId] = FIRST_POST_GENESIS_BATCH;
    }

    /// @dev Aggregates a chain batch root embedding `(_imtBegin, _imtEnd)` for `_sourceChainId` at batch
    /// time `_batchTs`, through the real `addChainBatchRootV32`. Returns the batch number used and the
    /// chain root immediately before the new batch leaf is pushed. Unlike the `_real*` proof builders,
    /// this low-level aggregation helper can advance a source chain beyond its first batch.
    function _aggregateBatch(
        uint256 _sourceChainId,
        bytes32 _imtBegin,
        bytes32 _imtEnd,
        uint256 _batchTs
    ) internal returns (uint256 batchNumber, bytes32 previousChainRoot) {
        _ensureChainRegistered(_sourceChainId);
        previousChainRoot = slMessageRoot.getChainRoot(_sourceChainId);
        batchNumber = _nextBatch[_sourceChainId]++;
        bytes32 chainBatchRoot = ChainBatchRootTree.compute(bytes32(0), bytes32(0), _imtBegin, _imtEnd);

        address chainSender = IBridgehubBase(msgRootBridgehub).getZKChain(_sourceChainId);
        vm.warp(_batchTs);
        vm.roll(++_slBlockCursor);
        vm.prank(chainSender);
        slMessageRoot.addChainBatchRootV32(_sourceChainId, batchNumber, chainBatchRoot);
    }

    /// @dev Imports the MessageRoot's CURRENT aggregated shared root into the real L2InteropRootStorage
    /// at `(builderSlChainId, slBlock)`, keyed by the current SL block and stamped with `block.timestamp`.
    function _importCurrentSharedRoot() internal returns (uint256 slBlock, uint256 rootTimestamp) {
        slBlock = block.number;
        rootTimestamp = block.timestamp;
        _seedSettlementLayerInteropRootWithValue(
            builderSlChainId,
            slBlock,
            rootTimestamp,
            slMessageRoot.getAggregatedRoot()
        );
    }

    /// @dev Assembles the real two-hop settlement proof for `_sourceChainId`'s FIRST post-genesis
    /// batch. The one-sibling path is valid only for batch 1: the new batch is the right child and the
    /// pre-push chain root is the genesis leaf on its left. Later batches fail explicitly rather than
    /// silently producing an invalid proof. `_imtRootLeafIndex` selects begin (2) / end (3); the top
    /// siblings reproduce {ChainBatchRootTree.compute}.
    function _realFirstPostGenesisBatchSettlementProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _imtRootLeafIndex,
        bytes32 _imtBegin,
        bytes32 _imtEnd,
        uint256 _batchTs,
        bytes32 _previousChainRoot,
        uint256 _slBlock
    ) internal view returns (bytes32[] memory proof) {
        if (_batchNumber != FIRST_POST_GENESIS_BATCH) {
            revert AtomicProofBuilderOnlySupportsFirstPostGenesisBatch(_sourceChainId, _batchNumber);
        }

        bytes32[] memory topSiblings = new bytes32[](ChainBatchRootTree.TREE_DEPTH);
        // Leaf 2 (begin): sibling at level 0 is leaf 3 (end); leaf 3 (end): sibling is leaf 2 (begin).
        topSiblings[0] = _imtRootLeafIndex == ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX ? _imtBegin : _imtEnd;
        topSiblings[1] = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        topSiblings[2] = ChainBatchRootTree.RESERVED_SUBTREE_NODE;

        // Chain tree: the real batch is the right child of the 2-leaf tree (genesis leaf on the left).
        bytes32[] memory chainSiblings = new bytes32[](1);
        chainSiblings[0] = _previousChainRoot;

        bytes32[] memory sharedSiblings = slMessageRoot.getMerklePathForChain(_sourceChainId);
        uint256 sharedMask = slMessageRoot.chainIndex(_sourceChainId);

        uint256 topLen = ChainBatchRootTree.TREE_DEPTH;
        uint256 nShared = sharedSiblings.length;
        // hop1: meta1(1)+top(3)+batchTs(1)+chainMask(1)+chainSibling(1)+slPacked(1)+slChainId(1); hop2: meta2(1)+shared(nShared)
        proof = new bytes32[](topLen + nShared + 7);
        uint256 p = 0;
        proof[p++] = _composeMetadata({_logLeafProofLen: topLen, _batchLeafProofLen: 1, _finalProofNode: false});
        for (uint256 i = 0; i < topLen; ++i) {
            proof[p++] = topSiblings[i];
        }
        proof[p++] = bytes32(_batchTs);
        proof[p++] = bytes32(_batchNumber); // first post-genesis batch is the right child (mask 0b1)
        proof[p++] = chainSiblings[0];
        proof[p++] = bytes32((_slBlock << 128) | sharedMask);
        proof[p++] = bytes32(builderSlChainId);
        proof[p++] = _composeMetadata({_logLeafProofLen: nShared, _batchLeafProofLen: 0, _finalProofNode: true});
        for (uint256 i = 0; i < nShared; ++i) {
            proof[p++] = sharedSiblings[i];
        }
    }

    /// @notice A REAL inclusion proof for the committed value at `_leafIndex`: aggregates the IMT end
    /// root as a chain batch root at `_batchTs`, imports the shared root, and builds the proof from the
    /// live trees. Verifies through the real {L2MessageVerification}.
    function _realInclusionProof(
        uint256 _sourceChainId,
        uint256 _leafIndex,
        uint256 _batchTs
    ) internal returns (ImtProof memory) {
        bytes32 imtEnd = tree.root();
        bytes32 imtBegin = ChainBatchRootTree.EMPTY_IMT_ROOT;
        (uint256 batchNumber, bytes32 previousChainRoot) = _aggregateBatch(_sourceChainId, imtBegin, imtEnd, _batchTs);
        (uint256 slBlock, ) = _importCurrentSharedRoot();
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: batchNumber,
                chainImtRoot: imtEnd,
                provesAgainstBeginRoot: false,
                settlementProof: _realFirstPostGenesisBatchSettlementProof(
                    _sourceChainId,
                    batchNumber,
                    ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
                    imtBegin,
                    imtEnd,
                    _batchTs,
                    previousChainRoot,
                    slBlock
                ),
                leaf: tree.leafAt(_leafIndex),
                imtLeafIndex: _leafIndex,
                imtProof: tree.merklePath(_leafIndex)
            });
    }

    /// @notice A REAL timeout absence proof for `_absentValue` via the BEGIN branch: aggregates a LATE
    /// batch (`_batchTs > DEADLINE`) whose begin IMT root excludes the value, imports the shared root
    /// (created after the deadline), and builds the proof from the live trees.
    function _realTimeoutBeginProof(
        uint256 _sourceChainId,
        uint256 _absentValue,
        uint256 _batchTs
    ) internal returns (ImtProof memory) {
        require(_batchTs > DEADLINE, "begin branch needs a late batch");
        bytes32 imtSnapshot = tree.root(); // excludes the never-inserted absent value
        (uint256 batchNumber, bytes32 previousChainRoot) = _aggregateBatch(
            _sourceChainId,
            imtSnapshot,
            imtSnapshot,
            _batchTs
        );
        (uint256 slBlock, ) = _importCurrentSharedRoot(); // T == _batchTs > DEADLINE
        uint256 lowIndex = _lowNullifierIndex(_absentValue);
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: batchNumber,
                chainImtRoot: imtSnapshot,
                provesAgainstBeginRoot: true,
                settlementProof: _realFirstPostGenesisBatchSettlementProof(
                    _sourceChainId,
                    batchNumber,
                    ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
                    imtSnapshot,
                    imtSnapshot,
                    _batchTs,
                    previousChainRoot,
                    slBlock
                ),
                leaf: tree.leafAt(lowIndex),
                imtLeafIndex: lowIndex,
                imtProof: tree.merklePath(lowIndex)
            });
    }

    /// @notice A REAL timeout absence proof for `_absentValue` via the END branch: aggregates an
    /// IN-TIME batch (`_batchTs <= DEADLINE`) as the source chain's LAST batch, then bumps the shared
    /// root past the deadline with a second (halted-peer) chain's aggregation, imports that later root,
    /// and proves absence from the in-time batch's end root.
    function _realTimeoutEndProof(
        uint256 _sourceChainId,
        uint256 _absentValue,
        uint256 _batchTs
    ) internal returns (ImtProof memory) {
        require(_batchTs <= DEADLINE, "end branch needs an in-time batch");
        bytes32 imtSnapshot = tree.root();
        (uint256 batchNumber, bytes32 previousChainRoot) = _aggregateBatch(
            _sourceChainId,
            imtSnapshot,
            imtSnapshot,
            _batchTs
        );
        // Bump the shared root past the deadline via a different chain, keeping the source chain's
        // in-time batch its last one. `getMerklePathForChain`/`chainIndex` below reflect the post-bump tree.
        uint256 bumpChain = _sourceChainId + 1_000_000;
        _aggregateBatch(bumpChain, imtSnapshot, imtSnapshot, uint256(DEADLINE) + 5);
        (uint256 slBlock, ) = _importCurrentSharedRoot(); // T == DEADLINE + 5 > DEADLINE

        uint256 lowIndex = _lowNullifierIndex(_absentValue);
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: batchNumber,
                chainImtRoot: imtSnapshot,
                provesAgainstBeginRoot: false,
                settlementProof: _realFirstPostGenesisBatchSettlementProof(
                    _sourceChainId,
                    batchNumber,
                    ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
                    imtSnapshot,
                    imtSnapshot,
                    _batchTs,
                    previousChainRoot,
                    slBlock
                ),
                leaf: tree.leafAt(lowIndex),
                imtLeafIndex: lowIndex,
                imtProof: tree.merklePath(lowIndex)
            });
    }

    // Mocks / real-storage seeding

    /// @dev Drives the (separately-tested) cross-chain leaf verifier to `_ok` for every call.
    function _mockVerifier(bool _ok) internal {
        vm.mockCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared.selector),
            abi.encode(_ok)
        );
    }

    /// @dev Imports the settlement-layer interop root `(root, timestamp)` tuple into the REAL root storage through the
    /// production bootloader entry point. The root value is a derived placeholder (the default verifier
    /// mock does not read it); use {_seedSettlementLayerInteropRootWithValue} when the real verifier must
    /// authenticate against a specific reconstructed root.
    function _seedSettlementLayerInteropRoot(uint256 _slChainId, uint256 _slBlock, uint256 _timestamp) internal {
        _seedSettlementLayerInteropRootWithValue(
            _slChainId,
            _slBlock,
            _timestamp,
            keccak256(abi.encode("sl-interop-root", _slChainId, _slBlock))
        );
    }

    /// @dev Like {_seedSettlementLayerInteropRoot}, but imports a caller-chosen `_root` — the value the
    /// real `L2MessageVerification` terminates its recursion against (`interopRoots(...).root`, which
    /// {L2InteropRootStorage} stores verbatim from `sides[0]`).
    function _seedSettlementLayerInteropRootWithValue(
        uint256 _slChainId,
        uint256 _slBlock,
        uint256 _timestamp,
        bytes32 _root
    ) internal {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = _root;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(
            InteropRoot({chainId: _slChainId, blockOrBatchNumber: _slBlock, timestamp: _timestamp, sides: sides})
        );
    }

    /// @dev Asserts that the proof library authenticates `_proof.chainImtRoot` as exactly the
    /// chain-batch-root leaf `_imtRootLeafIndex` (2 = batch begin, 3 = batch end) of the claimed
    /// batch. Works over both the real verifier and a locally-stubbed one; this expectation makes the
    /// adapter boundary fail if chain id, batch, leaf index, root, or proof drift.
    function _expectRootAuthentication(ImtProof memory _proof, uint256 _imtRootLeafIndex) internal {
        vm.expectCall(
            address(L2_MESSAGE_VERIFICATION),
            abi.encodeWithSelector(
                L2_MESSAGE_VERIFICATION.proveL2LeafInclusionShared.selector,
                _proof.sourceChainId,
                _proof.batchNumber,
                _imtRootLeafIndex,
                _proof.chainImtRoot,
                _proof.settlementProof
            )
        );
    }

    // Tree helpers

    /// @dev Inserts `_value` into the real tree as the canonical appender; returns its leaf index.
    function _insertCommit(uint256 _value) internal returns (uint256 index) {
        uint256 low = _lowNullifierIndex(_value);
        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        (index, ) = tree.insert(_value, low);
    }

    /// @dev Finds the leaf that brackets `_value` in the sorted linked list (its low-nullifier /
    /// predecessor). Reverts if `_value` is already present — by design there is no bracketing leaf for
    /// a present value, which is exactly why an in-tree value cannot be given a non-inclusion proof.
    function _lowNullifierIndex(uint256 _value) internal view returns (uint256) {
        uint256 count = tree.leafCount();
        for (uint256 i = 0; i < count; ++i) {
            IMTLeaf memory leaf = tree.leafAt(i);
            if (leaf.value < _value && (leaf.nextValue == 0 || leaf.nextValue > _value)) {
                return i;
            }
        }
        revert("AtomicInteropProofBuilder: no low-nullifier (value present or tree empty)");
    }

    /// @dev Finds the leaf whose `nextValue == _value`, i.e. the predecessor of a *present* value. Used to
    /// build an (illegitimate) non-inclusion proof for an in-tree value and show the engine rejects it.
    function _predecessorIndexOf(uint256 _value) internal view returns (uint256) {
        uint256 count = tree.leafCount();
        for (uint256 i = 0; i < count; ++i) {
            if (tree.leafAt(i).nextValue == _value) {
                return i;
            }
        }
        revert("AtomicInteropProofBuilder: no predecessor (value absent)");
    }

    // settlementProof-blob assembler

    /// @dev Builds the proof-metadata word (top 4 bytes: version, logLeafProofLen, batchLeafProofLen,
    /// finalProofNode; remaining bytes zero — the format `MessageHashing.parseProofMetadata` expects).
    function _composeMetadata(
        uint256 _logLeafProofLen,
        uint256 _batchLeafProofLen,
        bool _finalProofNode
    ) internal pure returns (bytes32) {
        return
            bytes32(
                (uint256(SUPPORTED_PROOF_METADATA_VERSION) << 248) |
                    (_logLeafProofLen << 240) |
                    (_batchLeafProofLen << 232) |
                    ((_finalProofNode ? uint256(1) : uint256(0)) << 224)
            );
    }

    /// @dev A minimal well-formed *non-final* `settlementProof` parsing to the given
    /// `(slChainId, slBlock, l1Timestamp)` and batch-leaf path, with the leaf-to-chain-batch-root
    /// section at exactly {ChainBatchRootTree.TREE_DEPTH} hops as the library enforces. Dummy siblings
    /// suffice: the resulting roots are never checked here because the leaf verifier is mocked.
    /// @param _batchLeafSiblings Batch-leaf path in the chain's batch tree (empty = single-leaf tree,
    /// which trivially satisfies the timeout protocol's last-batch check).
    function _settlementProof(
        uint256 _slChainId,
        uint256 _slBlock,
        uint256 _l1Timestamp,
        bytes32[] memory _batchLeafSiblings
    ) internal pure returns (bytes32[] memory proof) {
        // Mask 0 = the batch leaf is the leftmost leaf of the chain's batch tree.
        return _settlementProofWithMask(_slChainId, _slBlock, _l1Timestamp, 0, _batchLeafSiblings);
    }

    /// @dev Like {_settlementProof}, with a caller-chosen `batchLeafProofMask`. The mask encodes the
    /// batch leaf's position in the chain's batch tree (bit `i` = 1 iff the node is a RIGHT child at
    /// level `i`), which is what the timeout protocol's last-batch check inspects: on every
    /// left-child level the right sibling must be the empty-subtree cascade, while right-child
    /// levels may carry populated left siblings.
    function _settlementProofWithMask(
        uint256 _slChainId,
        uint256 _slBlock,
        uint256 _l1Timestamp,
        uint256 _batchLeafProofMask,
        bytes32[] memory _batchLeafSiblings
    ) internal pure returns (bytes32[] memory proof) {
        uint256 topLen = ChainBatchRootTree.TREE_DEPTH;
        // Layout: [metadata, topSiblings(3), l1Timestamp, batchLeafProofMask, batchSiblings(n),
        //          slPackedInfo, slChainId]
        proof = new bytes32[](topLen + 5 + _batchLeafSiblings.length);
        proof[0] = _composeMetadata({
            _logLeafProofLen: topLen,
            _batchLeafProofLen: _batchLeafSiblings.length,
            _finalProofNode: false
        });
        for (uint256 i = 0; i < topLen; ++i) {
            proof[1 + i] = bytes32(uint256(0xdead)); // dummy top-tree sibling
        }
        proof[topLen + 1] = bytes32(_l1Timestamp);
        proof[topLen + 2] = bytes32(_batchLeafProofMask);
        for (uint256 i = 0; i < _batchLeafSiblings.length; ++i) {
            proof[topLen + 3 + i] = _batchLeafSiblings[i];
        }
        proof[topLen + 3 + _batchLeafSiblings.length] = bytes32(_slBlock << 128); // (slBlock << 128) | mask
        proof[topLen + 4 + _batchLeafSiblings.length] = bytes32(_slChainId);
    }

    /// @dev A *final* `settlementProof` (single-level / commit-based): carries no settlement-layer
    /// batch reference, so `AtomicInteropProof` rejects it with `ProofMissingSettlementLayerBatch`.
    function _finalSettlementProof() internal pure returns (bytes32[] memory proof) {
        uint256 topLen = ChainBatchRootTree.TREE_DEPTH;
        proof = new bytes32[](topLen + 1);
        proof[0] = _composeMetadata({_logLeafProofLen: topLen, _batchLeafProofLen: 0, _finalProofNode: true});
        for (uint256 i = 0; i < topLen; ++i) {
            proof[1 + i] = bytes32(uint256(0xdead)); // dummy log-leaf-proof sibling
        }
    }

    /// @dev The `DynamicIncrementalMerkle` empty-subtree cascade the settlement layer's chain tree is
    /// built with: `zeros[0] = CHAIN_TREE_EMPTY_ENTRY_HASH`, `zeros[i+1] = keccak(zeros[i] || zeros[i])`.
    /// A batch-leaf path made of these right siblings marks the leaf as the chain's LAST batch.
    function _emptySubtreeCascade(uint256 _levels) internal pure returns (bytes32[] memory siblings) {
        siblings = new bytes32[](_levels);
        bytes32 zero = CHAIN_TREE_EMPTY_ENTRY_HASH;
        for (uint256 i = 0; i < _levels; ++i) {
            siblings[i] = zero;
            zero = keccak256(bytes.concat(zero, zero));
        }
    }

    // ImtProof assemblers

    /// @dev Inclusion proof for a value already inserted at `_leafIndex` in the real tree.
    function _inclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex,
        uint256 _slChainId,
        uint256 _slBlock,
        uint256 _l1Timestamp
    ) internal view returns (ImtProof memory) {
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                // The finality path always authenticates the end root; the branch bool is ignored.
                provesAgainstBeginRoot: false,
                settlementProof: _settlementProof(_slChainId, _slBlock, _l1Timestamp, new bytes32[](0)),
                leaf: tree.leafAt(_leafIndex),
                imtLeafIndex: _leafIndex,
                imtProof: tree.merklePath(_leafIndex)
            });
    }

    /// @dev Non-inclusion proof for an absent `_absentValue`: uses its low-nullifier (predecessor)
    /// leaf. The empty batch-leaf path marks the batch as the chain's last inside the settlement-layer interop root
    /// (single-leaf chain tree), so the proof is valid for both timeout branches.
    function _nonInclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _absentValue,
        uint256 _slChainId,
        uint256 _slBlock,
        uint256 _l1Timestamp
    ) internal view returns (ImtProof memory) {
        uint256 lowIndex = _lowNullifierIndex(_absentValue);
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: tree.root(),
                // Declare the branch the way an honest prover does: begin root for a late batch,
                // end root for an in-time one. Tests overriding the declaration set the field
                // explicitly after building.
                provesAgainstBeginRoot: _l1Timestamp > DEADLINE,
                settlementProof: _settlementProof(_slChainId, _slBlock, _l1Timestamp, new bytes32[](0)),
                leaf: tree.leafAt(lowIndex),
                imtLeafIndex: lowIndex,
                imtProof: tree.merklePath(lowIndex)
            });
    }
}
