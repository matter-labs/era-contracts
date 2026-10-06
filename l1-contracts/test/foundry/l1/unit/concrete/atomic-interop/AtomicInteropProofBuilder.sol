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
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
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
///     production `addSingleInteropRoot` entry point (pranked as the bootloader), so every root a proof
///     terminates at — and the timeout protocol's `(root, timestamp)` tuple — is served by the real
///     storage.
///   - A REAL {L2MessageVerification} authenticates every proof. Two builder families feed it:
///     - The `_real*` builders aggregate a chain batch root through a REAL {L1MessageRoot}
///       (`addChainBatchRootV32`), read the shared-tree path from it and import the shared root. They
///       intentionally cover only a source chain's first post-genesis batch: their one-sibling
///       chain-tree path is valid only for batch 1, and a later batch fails explicitly with
///       {AtomicProofBuilderOnlySupportsFirstPostGenesisBatch}. Cache a proof or use a distinct source
///       chain when a test needs more than one proof in the same fixture.
///     - {_settlementProof} / {_finalSettlementProof} forward-compute the proof together with the root
///       it terminates at, reaching shapes live aggregation cannot: a grown batch tree with a chosen
///       mask, a final-node proof, any timestamp or settlement layer, the local chain as source.
///       Callers import the returned root to authenticate, or withhold it to make the verifier reject.
///   - Every builder gives the batch distinct begin and end IMT roots, so a proof authenticates its
///     IMT root as exactly one chain-batch-root leaf and the real verifier enforces the leaf index.
///
/// Setup additionally stubs read-side WIRING (not proof-path logic): the L2 Bridgehub registry /
/// chain-getter views the real aggregation oracle consults (`_ensureChainRegistered` /
/// `_setUpAtomicFixtures`), so the canonical predeploys resolve without deploying the full bridgehub
/// stack. None of these stubs feeds the Merkle math the proofs authenticate against.
abstract contract AtomicInteropProofBuilder is AtomicPredeployFixture {
    /// @dev The settlement layer every atomic flow in these suites declares (L1).
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1;
    /// @dev The flow deadline all proofs are built against (shared with the tests so the `_realTimeout*`
    /// builders can check their batch timestamp against the branch they build).
    uint64 internal constant DEADLINE = 1_000;
    /// @dev The IMT root at the batch boundary a proof does not present: the end root when it proves
    /// the begin root, and vice versa. It differs from every tree root, so begin != end.
    bytes32 internal constant OTHER_IMT_ROOT = keccak256("the batch's other IMT root");

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
    /// so proofs authenticate against genuinely imported roots.
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
        _importInteropRoot(builderSlChainId, slBlock, rootTimestamp, slMessageRoot.getAggregatedRoot());
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
                settlementProof: _realFirstPostGenesisBatchSettlementProof({
                    _sourceChainId: _sourceChainId,
                    _batchNumber: batchNumber,
                    _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
                    _imtBegin: imtBegin,
                    _imtEnd: imtEnd,
                    _batchTs: _batchTs,
                    _previousChainRoot: previousChainRoot,
                    _slBlock: slBlock
                }),
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
        bytes32 imtBegin = tree.root(); // excludes the never-inserted absent value
        (uint256 batchNumber, bytes32 previousChainRoot) = _aggregateBatch(
            _sourceChainId,
            imtBegin,
            OTHER_IMT_ROOT,
            _batchTs
        );
        (uint256 slBlock, ) = _importCurrentSharedRoot(); // T == _batchTs > DEADLINE
        uint256 lowIndex = _lowNullifierIndex(_absentValue);
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: batchNumber,
                chainImtRoot: imtBegin,
                provesAgainstBeginRoot: true,
                settlementProof: _realFirstPostGenesisBatchSettlementProof({
                    _sourceChainId: _sourceChainId,
                    _batchNumber: batchNumber,
                    _imtRootLeafIndex: ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
                    _imtBegin: imtBegin,
                    _imtEnd: OTHER_IMT_ROOT,
                    _batchTs: _batchTs,
                    _previousChainRoot: previousChainRoot,
                    _slBlock: slBlock
                }),
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
        bytes32 imtEnd = tree.root();
        (uint256 batchNumber, bytes32 previousChainRoot) = _aggregateBatch(
            _sourceChainId,
            OTHER_IMT_ROOT,
            imtEnd,
            _batchTs
        );
        // Bump the shared root past the deadline via a different chain, keeping the source chain's
        // in-time batch its last one. `getMerklePathForChain`/`chainIndex` below reflect the post-bump tree.
        uint256 bumpChain = _sourceChainId + 1_000_000;
        _aggregateBatch(bumpChain, imtEnd, imtEnd, uint256(DEADLINE) + 5);
        (uint256 slBlock, ) = _importCurrentSharedRoot(); // T == DEADLINE + 5 > DEADLINE

        uint256 lowIndex = _lowNullifierIndex(_absentValue);
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: batchNumber,
                chainImtRoot: imtEnd,
                provesAgainstBeginRoot: false,
                settlementProof: _realFirstPostGenesisBatchSettlementProof({
                    _sourceChainId: _sourceChainId,
                    _batchNumber: batchNumber,
                    _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
                    _imtBegin: OTHER_IMT_ROOT,
                    _imtEnd: imtEnd,
                    _batchTs: _batchTs,
                    _previousChainRoot: previousChainRoot,
                    _slBlock: slBlock
                }),
                leaf: tree.leafAt(lowIndex),
                imtLeafIndex: lowIndex,
                imtProof: tree.merklePath(lowIndex)
            });
    }

    // Real-storage seeding

    /// @dev Imports `(_root, _timestamp)` at `(_chainId, _blockOrBatchNumber)` into the REAL root storage
    /// through the production bootloader entry point. `_root` is what the real `L2MessageVerification`
    /// terminates its recursion against (`interopRoots(...).root`, stored verbatim from `sides[0]`).
    function _importInteropRoot(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _timestamp,
        bytes32 _root
    ) internal {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = _root;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(
            InteropRoot({
                chainId: _chainId,
                blockOrBatchNumber: _blockOrBatchNumber,
                timestamp: _timestamp,
                sides: sides
            })
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

    /// @dev The chain batch root of a batch with zero logs and multichain roots, `_imtRoot` at IMT leaf
    /// `_imtRootLeafIndex` (2 = begin, 3 = end) and `_otherImtRoot` at the other IMT leaf.
    function _chainBatchRoot(
        bytes32 _imtRoot,
        uint256 _imtRootLeafIndex,
        bytes32 _otherImtRoot
    ) internal pure returns (bytes32) {
        return
            _imtRootLeafIndex == ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX
                ? ChainBatchRootTree.compute(bytes32(0), bytes32(0), _imtRoot, _otherImtRoot)
                : ChainBatchRootTree.compute(bytes32(0), bytes32(0), _otherImtRoot, _imtRoot);
    }

    /// @dev Forward-computes a two-hop `settlementProof` that authenticates `_imtRoot` as chain-batch-root
    /// leaf `_imtRootLeafIndex` of `(_sourceChainId, _batchNumber)`, and the aggregated root it terminates
    /// at; the real verifier accepts it once `aggregatedRoot` is imported at `(_slChainId, _slBlock)`.
    /// Hop 2 is a single-leaf aggregation tree with no siblings, so the chain-id leaf is the root.
    /// @param _otherImtRoot The batch's other IMT root; a distinct value binds the proof to one IMT leaf.
    /// @param _batchLeafProofMask The batch leaf's position in the chain's batch tree (bit `i` = 1 iff
    /// the node is a RIGHT child at level `i`), which the timeout end branch's last-batch check reads.
    /// @param _batchLeafSiblings The batch leaf's path in the chain's batch tree (empty = single leaf).
    function _settlementProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        bytes32 _imtRoot,
        uint256 _imtRootLeafIndex,
        bytes32 _otherImtRoot,
        uint256 _slChainId,
        uint256 _slBlock,
        uint256 _l1Timestamp,
        uint256 _batchLeafProofMask,
        bytes32[] memory _batchLeafSiblings
    ) internal pure returns (bytes32[] memory proof, bytes32 aggregatedRoot) {
        {
            bytes32 batchLeaf = MessageHashing.batchLeafHash(
                _chainBatchRoot(_imtRoot, _imtRootLeafIndex, _otherImtRoot),
                _batchNumber,
                _l1Timestamp
            );
            bytes32 chainIdRoot = Merkle.calculateRootMemory(_batchLeafSiblings, _batchLeafProofMask, batchLeaf);
            aggregatedRoot = MessageHashing.chainIdLeafHash(chainIdRoot, _sourceChainId);
        }

        uint256 topLen = ChainBatchRootTree.TREE_DEPTH;
        uint256 k = _batchLeafSiblings.length;
        // hop1: [meta1][3 top siblings][l1Timestamp][batchLeafMask][k batch siblings][slPacked][slChainId]
        // hop2: [meta2(final)], with no siblings
        proof = new bytes32[](topLen + 6 + k);
        proof[0] = _composeMetadata({_logLeafProofLen: topLen, _batchLeafProofLen: k, _finalProofNode: false});
        proof[1] = _otherImtRoot;
        proof[2] = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        proof[3] = ChainBatchRootTree.RESERVED_SUBTREE_NODE;
        proof[topLen + 1] = bytes32(_l1Timestamp);
        proof[topLen + 2] = bytes32(_batchLeafProofMask);
        for (uint256 i = 0; i < k; ++i) {
            proof[topLen + 3 + i] = _batchLeafSiblings[i];
        }
        proof[topLen + 3 + k] = bytes32(_slBlock << 128); // (slBlock << 128) | slBatchRootMask(0)
        proof[topLen + 4 + k] = bytes32(_slChainId);
        proof[topLen + 5 + k] = _composeMetadata({_logLeafProofLen: 0, _batchLeafProofLen: 0, _finalProofNode: true});
    }

    /// @dev A *final* (single-hop) `settlementProof` that authenticates `_imtRoot` as IMT leaf
    /// `_imtRootLeafIndex` of a batch whose other IMT root is `_otherImtRoot`. It carries no
    /// settlement-layer batch reference, so the L2 verifier terminates at
    /// `interopRoots(sourceChainId, batchNumber)` and accepts it once `chainBatchRoot` is imported there.
    function _finalSettlementProof(
        bytes32 _imtRoot,
        uint256 _imtRootLeafIndex,
        bytes32 _otherImtRoot
    ) internal pure returns (bytes32[] memory proof, bytes32 chainBatchRoot) {
        chainBatchRoot = _chainBatchRoot(_imtRoot, _imtRootLeafIndex, _otherImtRoot);
        proof = new bytes32[](ChainBatchRootTree.TREE_DEPTH + 1);
        proof[0] = _composeMetadata({
            _logLeafProofLen: ChainBatchRootTree.TREE_DEPTH,
            _batchLeafProofLen: 0,
            _finalProofNode: true
        });
        proof[1] = _otherImtRoot;
        proof[2] = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        proof[3] = ChainBatchRootTree.RESERVED_SUBTREE_NODE;
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

    // ImtProof assemblers over {_settlementProof}, presenting the real tree's root against
    // {OTHER_IMT_ROOT}: import `aggregatedRoot` at `(_slChainId, _slBlock)` for the proof to authenticate.

    /// @dev Inclusion proof for a value already inserted at `_leafIndex` in the real tree, against the
    /// batch-END root.
    function _inclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex,
        uint256 _slChainId,
        uint256 _slBlock,
        uint256 _l1Timestamp
    ) internal view returns (ImtProof memory proof, bytes32 aggregatedRoot) {
        bytes32[] memory settlementProof;
        (settlementProof, aggregatedRoot) = _settlementProof({
            _sourceChainId: _sourceChainId,
            _batchNumber: _batchNumber,
            _imtRoot: tree.root(),
            _imtRootLeafIndex: ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
            _otherImtRoot: OTHER_IMT_ROOT,
            _slChainId: _slChainId,
            _slBlock: _slBlock,
            _l1Timestamp: _l1Timestamp,
            _batchLeafProofMask: 0,
            _batchLeafSiblings: new bytes32[](0)
        });
        proof = ImtProof({
            sourceChainId: _sourceChainId,
            batchNumber: _batchNumber,
            chainImtRoot: tree.root(),
            // The finality path always authenticates the end root; the branch bool is ignored.
            provesAgainstBeginRoot: false,
            settlementProof: settlementProof,
            leaf: tree.leafAt(_leafIndex),
            imtLeafIndex: _leafIndex,
            imtProof: tree.merklePath(_leafIndex)
        });
    }

    /// @dev Non-inclusion proof for an absent `_absentValue`: uses its low-nullifier (predecessor)
    /// leaf, presents the tree root as IMT leaf `_imtRootLeafIndex` and declares the matching timeout
    /// branch.
    function _nonInclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _absentValue,
        uint256 _imtRootLeafIndex,
        uint256 _slChainId,
        uint256 _slBlock,
        uint256 _l1Timestamp,
        uint256 _batchLeafProofMask,
        bytes32[] memory _batchLeafSiblings
    ) internal view returns (ImtProof memory proof, bytes32 aggregatedRoot) {
        bytes32[] memory settlementProof;
        (settlementProof, aggregatedRoot) = _settlementProof({
            _sourceChainId: _sourceChainId,
            _batchNumber: _batchNumber,
            _imtRoot: tree.root(),
            _imtRootLeafIndex: _imtRootLeafIndex,
            _otherImtRoot: OTHER_IMT_ROOT,
            _slChainId: _slChainId,
            _slBlock: _slBlock,
            _l1Timestamp: _l1Timestamp,
            _batchLeafProofMask: _batchLeafProofMask,
            _batchLeafSiblings: _batchLeafSiblings
        });
        uint256 lowIndex = _lowNullifierIndex(_absentValue);
        proof = ImtProof({
            sourceChainId: _sourceChainId,
            batchNumber: _batchNumber,
            chainImtRoot: tree.root(),
            provesAgainstBeginRoot: _imtRootLeafIndex == ChainBatchRootTree.IMT_BEGIN_ROOT_LEAF_INDEX,
            settlementProof: settlementProof,
            leaf: tree.leafAt(lowIndex),
            imtLeafIndex: lowIndex,
            imtProof: tree.merklePath(lowIndex)
        });
    }
}
