// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISimulator, FlowState, PlanStep, PeerSimLog} from "./ISimulator.sol";
import {IIMTFactRecorder} from "./IIMTFactRecorder.sol";
import {FactHashing} from "./IMTFactRecorder.sol";
import {IndexedMerkleTreeLib, IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {InteropBundle} from "../common/Messaging.sol";
import {InteropDataEncoding} from "./InteropDataEncoding.sol";
import {IMessageVerification} from "../common/interfaces/IMessageVerification.sol";
import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_IMT_FACT_RECORDER_ADDR,
    L2_MESSAGE_VERIFICATION_ADDR,
    L2_SIMULATOR_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "../common/L1ContractErrors.sol";
import {
    FlowAlreadyExists,
    FlowDeadlineInPast,
    FlowNotInitiated,
    FlowExpired,
    FlowNotExpired,
    NotIncludedInIMT,
    IncludedInIMT,
    EmptyBundleHash,
    BundleAlreadyAttached,
    FlowNotFinalized,
    UnexpectedSimulatedBundle,
    FlowNotSimulated,
    FlowAlreadySimulated,
    SelfChainInPeerLogs,
    PeerLogSenderMismatch,
    PeerLogNotIncluded,
    PeerLogTagMismatch,
    PeerLogFlowIdMismatch,
    DestChainNotInParticipatingSet,
    TooManyExpectedBundles,
    SimulationCompleted
} from "./SimulatorErrors.sol";

bytes4 constant SIMULATION_LOG_TAG = bytes4(keccak256("Simulator.simulationLog.v1"));
bytes4 constant FINALITY_DISPATCH_TAG = bytes4(keccak256("Simulator.finalityDispatch.v1"));

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See `ISimulator` for the protocol-level description.
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors.
/// State is initialized through `initL2`, called once via `L2_COMPLEX_UPGRADER_ADDR` during the
/// genesis upgrade.
contract Simulator is ISimulator, ReentrancyGuard {
    /// @dev Per-flow lifecycle state. Asset custody (if any) is held by `FlowAssetEscrow` and is
    /// independent of this struct — the Simulator never touches user assets.
    struct Flow {
        FlowState state;
        uint64 deadline;
        address registrar;
    }

    mapping(bytes32 flowId => Flow) public flows;

    /// @dev Optional binding from a private interop bundle hash to its containing flow. See
    /// `requireBundleFinalized`.
    mapping(bytes32 bundleHash => bytes32 flowId) public bundleFlow;

    /// @dev Per-flow durable record of bundle verify-hashes published by `simulate`. The order
    /// matches the order the user pre-staged the bundles; the same hashes are also emitted as
    /// L1Messenger logs in the same tx.
    mapping(bytes32 flowId => bytes32[]) internal _simulatedBundleHashes;

    /// @dev Parallel array to `_simulatedBundleHashes`: the `destinationChainId` declared for
    /// each pre-staged expected bundle. Linking on this chain reads these to verify that every
    /// chain it sends bundles to is in the participating set of `recordFinalitySignal`.
    mapping(bytes32 flowId => uint256[]) internal _simulatedDestChainIds;

    /// @dev Set true exactly once when `simulate` completes successfully for a flow. Local
    /// sanity gate consumed by `recordFinalitySignal`: a finality fact can't be inserted into
    /// the IMT for a flow whose plan never ran (or reverted) on *this* chain. NOT cross-chain
    /// linking — see the Phase 2 note in `recordFinalitySignal`.
    mapping(bytes32 flowId => bool) internal _flowSimulated;

    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) revert Unauthorized(msg.sender);
        _;
    }

    /// @notice One-shot initializer called from the L2 genesis upgrade.
    function initL2() external reentrancyGuardInitializer onlyUpgrader {}

    /// @inheritdoc ISimulator
    function registerFlow(bytes32 _flowId, uint64 _deadline) external nonReentrant {
        Flow storage flow = flows[_flowId];
        if (flow.state != FlowState.None) revert FlowAlreadyExists(_flowId);
        if (_deadline <= block.timestamp) revert FlowDeadlineInPast(_deadline);

        flow.state = FlowState.Initiated;
        flow.deadline = _deadline;
        flow.registrar = msg.sender;

        emit FlowRegistered(_flowId, msg.sender, _deadline);
    }

    /// @inheritdoc ISimulator
    function recordFinalitySignal(
        bytes32 _flowId,
        uint256 _lowLeafIndex,
        PeerSimLog[] calldata _peerLogs
    ) external returns (bytes32 newRoot, uint256 newLeafIndex) {
        Flow storage flow = _requireOpenFlow(_flowId);

        // Local sanity gate: this chain's plan must have completed cleanly via `simulate`.
        if (!_flowSimulated[_flowId]) revert FlowNotSimulated(_flowId);

        // Linking: verify every peer's sim log + check graph closure. Returns the deduped
        // peer chain id set so we can dispatch a finality notification to each below.
        uint256[] memory peerChainIds = _linkPeerLogs(_flowId, _peerLogs);

        (newRoot, newLeafIndex) = IIMTFactRecorder(L2_IMT_FACT_RECORDER_ADDR).recordFact(_flowId, _lowLeafIndex);
        emit FinalitySignal(_flowId, newRoot, newLeafIndex);

        // The source has just committed the canonical finality fact; it doesn't need to verify
        // a separate inclusion proof against its own root. Flip state directly.
        flow.state = FlowState.Finalized;
        emit FlowFinalized(_flowId);

        // Auto-dispatch a per-peer L2->L1 finality notification. Destinations observe these
        // off-chain (or via `L2InteropRootStorage`) as a trigger to call `finalize` with the
        // source's IMT inclusion proof. Pure L2->L1 messaging — no interop bundle, no fees.
        uint256 peerCount = peerChainIds.length;
        for (uint256 i; i < peerCount; ++i) {
            uint256 peerId = peerChainIds[i];
            bytes32 messageHash = L2ContractHelper.sendMessageToL1(
                abi.encode(FINALITY_DISPATCH_TAG, _flowId, peerId)
            );
            emit FinalityDispatched(_flowId, peerId, messageHash);
        }
    }

    /// @dev Verifies each peer chain's `Simulator.simulate` summary log against
    /// `L2InteropRootStorage[chainId, blockNumber]`, decodes the payload, and ensures the
    /// bundle graph closes — every destination chainId mentioned anywhere (local or peer) is
    /// in the participating set `{block.chainid} ∪ {peer chainIds}`. Returns the deduped
    /// peer chain ids (excluding self) for the caller to fan finality dispatches out to.
    function _linkPeerLogs(
        bytes32 _flowId,
        PeerSimLog[] calldata _peerLogs
    ) internal view returns (uint256[] memory peerChainIds) {
        uint256 peerCount = _peerLogs.length;

        // Participating set: self + each peer's chainId, deduped. Slot 0 holds self; slots
        // 1..len hold peers. `participatingLen` tracks the live prefix because Solidity
        // memory arrays can't shrink.
        uint256[] memory participating = new uint256[](peerCount + 1);
        participating[0] = block.chainid;
        uint256 participatingLen = 1;

        // Per-peer destinations are collected during the inclusion-verification loop and then
        // checked against the (final) participating set after the loop.
        uint256[][] memory peerDests = new uint256[][](peerCount);

        IMessageVerification verifier = IMessageVerification(L2_MESSAGE_VERIFICATION_ADDR);

        for (uint256 i; i < peerCount; ++i) {
            PeerSimLog calldata peer = _peerLogs[i];

            if (peer.chainId == block.chainid) revert SelfChainInPeerLogs();
            if (peer.message.sender != L2_SIMULATOR_ADDR) revert PeerLogSenderMismatch(peer.message.sender);

            bool included = verifier.proveL2MessageInclusionShared({
                _chainId: peer.chainId,
                _blockOrBatchNumber: peer.blockOrBatchNumber,
                _index: peer.messageIndex,
                _message: peer.message,
                _proof: peer.merkleProof
            });
            if (!included) revert PeerLogNotIncluded(peer.chainId);

            // Payload layout: `abi.encode(SIMULATION_LOG_TAG, flowId, verifyHashes[], destChainIds[])`.
            (bytes4 tag, bytes32 logFlowId, , uint256[] memory dests) = abi.decode(
                peer.message.data,
                (bytes4, bytes32, bytes32[], uint256[])
            );
            if (tag != SIMULATION_LOG_TAG) revert PeerLogTagMismatch(tag);
            if (logFlowId != _flowId) revert PeerLogFlowIdMismatch(logFlowId);

            peerDests[i] = dests;

            if (!_isInSet(peer.chainId, participating, participatingLen)) {
                participating[participatingLen] = peer.chainId;
                ++participatingLen;
            }
        }

        // Closure: every destChainId mentioned by *any* sim log (local or peer) must be in the
        // participating set. Otherwise the flow has dangling outbound bundles to a chain that
        // didn't participate.
        uint256[] storage localDests = _simulatedDestChainIds[_flowId];
        uint256 localLen = localDests.length;
        for (uint256 i; i < localLen; ++i) {
            uint256 d = localDests[i];
            if (!_isInSet(d, participating, participatingLen)) revert DestChainNotInParticipatingSet(d);
        }
        for (uint256 i; i < peerCount; ++i) {
            uint256[] memory dests = peerDests[i];
            uint256 destsLen = dests.length;
            for (uint256 j; j < destsLen; ++j) {
                if (!_isInSet(dests[j], participating, participatingLen)) {
                    revert DestChainNotInParticipatingSet(dests[j]);
                }
            }
        }

        // Strip self from `participating` (slot 0) before returning. The caller uses the
        // result to fan finality dispatches out to peer chains; self is excluded.
        peerChainIds = new uint256[](participatingLen - 1);
        for (uint256 i; i < participatingLen - 1; ++i) {
            peerChainIds[i] = participating[i + 1];
        }
    }

    function _isInSet(uint256 _val, uint256[] memory _set, uint256 _len) private pure returns (bool) {
        for (uint256 i; i < _len; ++i) {
            if (_set[i] == _val) return true;
        }
        return false;
    }

    /// @inheritdoc ISimulator
    function finalize(
        bytes32 _flowId,
        bytes32 _imtRoot,
        IMTLeaf calldata _leaf,
        uint256 _leafIndex,
        bytes32[] calldata _proof
    ) external nonReentrant {
        Flow storage flow = flows[_flowId];
        if (flow.state != FlowState.Initiated) revert FlowNotInitiated(_flowId);

        uint256 expected = FactHashing.factValue(L2_SIMULATOR_ADDR, _flowId);

        IMTLeaf memory leafCopy = _leaf;
        bytes32[] memory proofCopy = _proof;
        if (
            !IndexedMerkleTreeLib.verifyInclusion({
                _root: _imtRoot,
                _value: expected,
                _leaf: leafCopy,
                _leafIndex: _leafIndex,
                _proof: proofCopy
            })
        ) {
            revert NotIncludedInIMT(_flowId, _imtRoot);
        }

        flow.state = FlowState.Finalized;
        emit FlowFinalized(_flowId);
    }

    /// @inheritdoc ISimulator
    function revertExpired(
        bytes32 _flowId,
        bytes32 _imtRoot,
        IMTLeaf calldata _lowLeaf,
        uint256 _lowLeafIndex,
        bytes32[] calldata _lowLeafProof
    ) external nonReentrant {
        Flow storage flow = flows[_flowId];
        if (flow.state != FlowState.Initiated) revert FlowNotInitiated(_flowId);
        if (block.timestamp <= flow.deadline) revert FlowNotExpired(_flowId, flow.deadline);

        uint256 expected = FactHashing.factValue(L2_SIMULATOR_ADDR, _flowId);

        IMTLeaf memory leafCopy = _lowLeaf;
        bytes32[] memory proofCopy = _lowLeafProof;
        if (
            !IndexedMerkleTreeLib.verifyNonInclusion({
                _root: _imtRoot,
                _value: expected,
                _lowLeaf: leafCopy,
                _lowLeafIndex: _lowLeafIndex,
                _lowLeafProof: proofCopy
            })
        ) revert IncludedInIMT(_flowId, _imtRoot);

        flow.state = FlowState.Reverted;
        emit FlowReverted(_flowId);
    }

    /// @inheritdoc ISimulator
    function requireBundleFinalized(bytes32 _bundleHash) external view {
        bytes32 flowId = bundleFlow[_bundleHash];
        if (flowId == bytes32(0)) return;
        if (flows[flowId].state != FlowState.Finalized) revert FlowNotFinalized(flowId);
    }

    /// @dev Common gate used by `recordFinalitySignal` and `dispatchFinality`: the local flow
    /// must exist, be in `Initiated`, and not yet past its deadline. Returns the flow storage
    /// pointer so the caller can read the registrar without re-loading.
    function _requireOpenFlow(bytes32 _flowId) internal view returns (Flow storage flow) {
        flow = flows[_flowId];
        if (flow.state != FlowState.Initiated) revert FlowNotInitiated(_flowId);
        if (block.timestamp > flow.deadline) revert FlowExpired(_flowId);
    }

    /*//////////////////////////////////////////////////////////////
                        Simulation phase (per spec)
    //////////////////////////////////////////////////////////////*/

    // Transient layout owned by Simulator. Two regions, with different revert semantics:
    //
    //   "Outer-frame" slots — set by `simulate` BEFORE entering `runPlan`. These survive the
    //   runPlan revert because they were written in `simulate`'s own frame:
    //     _SIM_FLOW_ID_SLOT       → bytes32   active sim flow id (0 when not in sim)
    //     _SIM_HASH_COUNT_SLOT    → uint256   pre-staged expected bundle count (0 → auto-record)
    //     keccak256("Simulator.sim.hash", i) → bytes32 expected hash at index i (pre-staged)
    //
    //   "Inner-frame" slots — written by `checkSimulation` while runPlan is executing. These
    //   are reverted along with everything else when runPlan reverts. `runPlan` reads them
    //   immediately before the revert and forwards the data through the revert payload (the
    //   only channel that survives the rollback). One bundle max — `TooManyExpectedBundles`.
    //     _AUTO_REC_COUNT_SLOT    → uint256   auto-record count (0 or 1)
    //     keccak256("Simulator.auto.hash", i) → bytes32 auto-recorded hash
    //     keccak256("Simulator.auto.dest", i) → uint256 auto-recorded dest chain id
    //     _AUTO_REC_BYTES_LEN_SLOT → uint256 bundle bytes length
    //     keccak256("Simulator.auto.bytes.chunk", i) → bytes32 32-byte chunk of bundle bytes
    bytes32 private constant _SIM_FLOW_ID_SLOT = keccak256("Simulator.sim.flowId");
    bytes32 private constant _SIM_HASH_COUNT_SLOT = keccak256("Simulator.sim.hashCount");
    bytes32 private constant _AUTO_REC_COUNT_SLOT = keccak256("Simulator.auto.count");
    bytes32 private constant _AUTO_REC_BYTES_LEN_SLOT = keccak256("Simulator.auto.bytes.len");

    function _simHashSlot(uint256 _idx) private pure returns (bytes32) {
        return keccak256(abi.encode("Simulator.sim.hash", _idx));
    }

    function _autoRecHashSlot(uint256 _idx) private pure returns (bytes32) {
        return keccak256(abi.encode("Simulator.auto.hash", _idx));
    }

    function _autoRecDestSlot(uint256 _idx) private pure returns (bytes32) {
        return keccak256(abi.encode("Simulator.auto.dest", _idx));
    }

    function _autoRecBytesChunkSlot(uint256 _i) private pure returns (bytes32) {
        return keccak256(abi.encode("Simulator.auto.bytes.chunk", _i));
    }

    function _tload(bytes32 _slot) private view returns (bytes32 value) {
        assembly {
            value := tload(_slot)
        }
    }

    function _tstore(bytes32 _slot, bytes32 _value) private {
        assembly {
            tstore(_slot, _value)
        }
    }

    /// @inheritdoc ISimulator
    function simulate(
        bytes32 _flowId,
        PlanStep[] calldata _steps,
        bytes[] calldata _expectedBundleBytes,
        bytes32[] calldata _inboundBundleHashes
    ) external returns (bytes32[] memory bundleHashes, bytes[] memory bundleBytes) {
        Flow storage flow = _requireOpenFlow(_flowId);
        if (msg.sender != flow.registrar) revert Unauthorized(msg.sender);
        // Once-only: the simulation log for a flow is the canonical commitment from this chain;
        // re-running would either duplicate the L1 logs or invite an attacker to overwrite them
        // with a different plan. Use a fresh flowId for a re-attempt.
        if (_flowSimulated[_flowId]) revert FlowAlreadySimulated(_flowId);
        // Empty plans are allowed (a flow with no cross-chain calls — just lock and finalize —
        // is a valid case). The runPlan call below is a cheap no-op when steps.length == 0.

        // Each chain may dispatch *at most one* outbound interop bundle per flow. The
        // restriction keeps the linking graph simple (every participating chain has at most
        // one outbound edge) and lets the protocol reason about one canonical "outcome hash"
        // per chain per flow. Multi-bundle topologies decompose into multiple flows.
        uint256 n = _expectedBundleBytes.length;
        if (n > 1) revert TooManyExpectedBundles(n);

        _attachInboundBundles(_flowId, _inboundBundleHashes);

        // Pre-stage the expected bundle hashes (if any) in transient slots. The hash format is
        // `encodeInteropBundleHash(block.chainid, bundleBytes)` — the same hash the destination
        // `InteropHandler` will look up to gate `executeBundle` on flow finality. If
        // `_expectedBundleBytes` is empty, simulate runs in auto-record mode: `checkSimulation`
        // captures the plan's first outbound bundle into transient storage for the outer frame
        // to commit.
        _stageExpectedBundles(_flowId, _expectedBundleBytes);

        // Run the plan via a self-call to `runPlan`, which always reverts with
        // `SimulationCompleted` on success. The EVM rolls back every state change made during
        // plan execution — InteropCenter's nonce bump, fee collection, event emissions, the
        // L2->L1 bundle message, all of it — so the simulation leaves no real on-chain
        // footprint. We then proceed in the outer (non-reverting) frame to commit our own
        // durable artefacts (simulation log + storage).
        //
        // try/catch is required to recover from the intentional sentinel revert. This usage is
        // distinct from the silent-fallback pattern that AGENTS.md bans: the catch
        // *explicitly* re-raises anything that isn't our sentinel (a real plan step failure or
        // a sim-mismatch revert from `Simulator.checkSimulation`).
        //
        // TODO: meter the gas used by `this.runPlan(...)` (sample `gasleft()` before/after) and
        // require an equivalent value to be locked up-front (e.g. via `FlowAssetEscrow`). The
        // locked value would then fund the destination chains' finalization txs so the user
        // sees free execution at finalize time — gas prepaid here at simulation time,
        // distributed to peers via the finality dispatch payload, the destination's finalize
        // entry pulls from it instead of charging the caller. Meaningfully harder than it looks
        // (cross-chain gas pricing, refund of overestimates, etc.) — design separately before
        // implementing.
        bytes32[] memory committedHashes;
        uint256[] memory committedDests;
        bytes[] memory committedBytes;
        try this.runPlan(_flowId, _steps) {
            // Unreachable: runPlan always reverts with `SimulationCompleted(...)`.
        } catch (bytes memory revertData) {
            // Verify the revert is our sentinel; otherwise bubble the original error.
            if (revertData.length < 4 || bytes4(revertData) != SimulationCompleted.selector) {
                assembly {
                    revert(add(revertData, 0x20), mload(revertData))
                }
            }
            (committedHashes, committedDests, committedBytes) = _decodeSimulationCompleted(revertData);
        }

        // Pre-staged mode: the input bytes are the canonical bytes; ignore whatever
        // runPlan bubbled up and rebuild from the user-provided input.
        if (n > 0) {
            committedHashes = new bytes32[](n);
            committedDests = new uint256[](n);
            committedBytes = new bytes[](n);
            for (uint256 i; i < n; ++i) {
                committedHashes[i] = InteropDataEncoding.encodeInteropBundleHash(block.chainid, _expectedBundleBytes[i]);
                committedDests[i] = abi.decode(_expectedBundleBytes[i], (InteropBundle)).destinationChainId;
                committedBytes[i] = _expectedBundleBytes[i];
            }
        }

        // Clear outer-frame transient slots used by checkSimulation's pre-staged matching.
        _tstore(_SIM_FLOW_ID_SLOT, bytes32(0));
        _tstore(_SIM_HASH_COUNT_SLOT, bytes32(0));
        for (uint256 i; i < n; ++i) {
            _tstore(_simHashSlot(i), bytes32(0));
        }

        if (committedHashes.length > 1) revert TooManyExpectedBundles(committedHashes.length);

        _commitSimulationResult(_flowId, committedHashes, committedDests);
        bundleHashes = committedHashes;
        bundleBytes = committedBytes;
    }

    /// @dev Bind inbound bundle hashes to this flow id. Done in the outer (non-reverting)
    /// frame so the binding survives `runPlan`'s sentinel revert and is durable for
    /// `requireBundleFinalized` lookups during destination-side execution. Each hash can
    /// only be bound to one flow — re-binding reverts.
    function _attachInboundBundles(bytes32 _flowId, bytes32[] calldata _inboundBundleHashes) internal {
        uint256 attachLen = _inboundBundleHashes.length;
        for (uint256 i; i < attachLen; ++i) {
            bytes32 inboundHash = _inboundBundleHashes[i];
            if (inboundHash == bytes32(0)) revert EmptyBundleHash();
            bytes32 existing = bundleFlow[inboundHash];
            if (existing != bytes32(0)) revert BundleAlreadyAttached(inboundHash, existing);
            bundleFlow[inboundHash] = _flowId;
            emit BundleAttachedToFlow(_flowId, inboundHash);
        }
    }

    /// @dev Pre-stage expected bundle hashes (if any) in transient slots. With an empty
    /// `_expectedBundleBytes` array we leave `_SIM_HASH_COUNT_SLOT == 0`, which puts
    /// `checkSimulation` into auto-record mode for the duration of `runPlan`.
    function _stageExpectedBundles(bytes32 _flowId, bytes[] calldata _expectedBundleBytes) internal {
        uint256 n = _expectedBundleBytes.length;
        _tstore(_SIM_FLOW_ID_SLOT, _flowId);
        _tstore(_SIM_HASH_COUNT_SLOT, bytes32(n));
        for (uint256 i; i < n; ++i) {
            bytes32 h = InteropDataEncoding.encodeInteropBundleHash(block.chainid, _expectedBundleBytes[i]);
            _tstore(_simHashSlot(i), h);
        }
    }

    /// @dev Decode the `SimulationCompleted(hashes, dests, bundleBytes)` revert payload
    /// runPlan emits before its sentinel revert. Strips the 4-byte selector and abi-decodes
    /// the parameter tuple. Reverts with the original payload if the selector doesn't match.
    function _decodeSimulationCompleted(
        bytes memory _revertData
    ) internal pure returns (bytes32[] memory hashes, uint256[] memory dests, bytes[] memory bundleBytes) {
        bytes memory body = new bytes(_revertData.length - 4);
        assembly {
            let src := add(_revertData, 0x24) // skip 32-byte length + 4-byte selector
            let dst := add(body, 0x20)
            let bodyLen := mload(body)
            let chunks := and(add(bodyLen, 31), not(31))
            for {
                let i := 0
            } lt(i, chunks) {
                i := add(i, 32)
            } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
        return abi.decode(body, (bytes32[], uint256[], bytes[]));
    }

    /// @dev Persist the committed bundle hashes + dest chain ids and emit the chain's
    /// canonical simulation log. Marks `_flowSimulated[_flowId]` so `recordFinalitySignal`
    /// can run later. Empty arrays are valid (a participating chain with no outbound bundles).
    function _commitSimulationResult(
        bytes32 _flowId,
        bytes32[] memory _hashes,
        uint256[] memory _dests
    ) internal {
        uint256 len = _hashes.length;
        for (uint256 i; i < len; ++i) {
            _simulatedBundleHashes[_flowId].push(_hashes[i]);
            _simulatedDestChainIds[_flowId].push(_dests[i]);
            emit SimulatedBundleRecorded(_flowId, i, _hashes[i]);
        }
        L2ContractHelper.sendMessageToL1(abi.encode(SIMULATION_LOG_TAG, _flowId, _hashes, _dests));
        _flowSimulated[_flowId] = true;
        emit SimulationLogPublished(_flowId, len);
    }

    /// @inheritdoc ISimulator
    function runPlan(bytes32 /* _flowId */, PlanStep[] calldata _steps) external {
        // Self-call target. Each step runs as a regular call and may mutate state — the
        // bundle creation logic in `InteropCenter.sendBundle` (nonce bump, fee collection,
        // event emission, L2->L1 messages) executes normally. We then ALWAYS revert with
        // `SimulationCompleted` so the EVM rolls back every one of those side effects: the
        // simulation has no lasting on-chain footprint outside of what `simulate` itself
        // commits in its outer (non-reverting) frame.
        //
        // Restricted to self-calls so simulation execution is scoped to `simulate`.
        if (msg.sender != address(this)) revert Unauthorized(msg.sender);
        uint256 len = _steps.length;
        for (uint256 i; i < len; ++i) {
            (bool ok, bytes memory ret) = _steps[i].target.call(_steps[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }

        // Read auto-recorded data from transient while it's still alive in this frame.
        // EIP-1153 reverts transient writes done in (or under) this frame, so we can't rely
        // on `simulate`'s catch reading them after the revert. The only way to bubble data
        // up through the revert is via the revert payload itself.
        uint256 autoCount = uint256(_tload(_AUTO_REC_COUNT_SLOT));
        bytes32[] memory hashes = new bytes32[](autoCount);
        uint256[] memory dests = new uint256[](autoCount);
        bytes[] memory bundleBytes = new bytes[](autoCount);
        for (uint256 i; i < autoCount; ++i) {
            hashes[i] = _tload(_autoRecHashSlot(i));
            dests[i] = uint256(_tload(_autoRecDestSlot(i)));
            if (i == 0) bundleBytes[0] = _tloadBundleBytes();
        }
        revert SimulationCompleted(hashes, dests, bundleBytes);
    }

    /// @inheritdoc ISimulator
    function checkSimulation(
        bytes32 _bundleHash,
        uint256 _destChainId,
        bytes calldata _bundleBytes
    ) external returns (bool) {
        bytes32 flowId = _tload(_SIM_FLOW_ID_SLOT);
        if (flowId == bytes32(0)) return false;
        uint256 count = uint256(_tload(_SIM_HASH_COUNT_SLOT));
        if (count == 0) {
            // Auto-record: capture the hash + dest chain id + raw bytes for the outer
            // frame. Bytes only stored for index 0 since `TooManyExpectedBundles` caps
            // committed bundles at 1.
            uint256 idx = uint256(_tload(_AUTO_REC_COUNT_SLOT));
            _tstore(_autoRecHashSlot(idx), _bundleHash);
            _tstore(_autoRecDestSlot(idx), bytes32(_destChainId));
            if (idx == 0) _tstoreBundleBytes(_bundleBytes);
            _tstore(_AUTO_REC_COUNT_SLOT, bytes32(idx + 1));
            return true;
        }
        for (uint256 i; i < count; ++i) {
            if (_tload(_simHashSlot(i)) == _bundleHash) return true;
        }
        revert UnexpectedSimulatedBundle(_bundleHash);
    }

    /// @dev Chunk-store bundle bytes into transient slots. Called by `checkSimulation`
    /// inside runPlan's call tree; `runPlan` reads them back via `_tloadBundleBytes` right
    /// before its sentinel revert. No clearing needed — the revert wipes the slots.
    function _tstoreBundleBytes(bytes calldata _bytes) private {
        uint256 len = _bytes.length;
        _tstore(_AUTO_REC_BYTES_LEN_SLOT, bytes32(len));
        uint256 chunks = (len + 31) / 32;
        for (uint256 i; i < chunks; ++i) {
            bytes32 chunk;
            assembly {
                chunk := calldataload(add(_bytes.offset, mul(i, 32)))
            }
            _tstore(_autoRecBytesChunkSlot(i), chunk);
        }
    }

    /// @dev Reassemble bytes from transient. Called from `runPlan` immediately before its
    /// sentinel revert, so the slots are still alive.
    function _tloadBundleBytes() private view returns (bytes memory result) {
        uint256 len = uint256(_tload(_AUTO_REC_BYTES_LEN_SLOT));
        result = new bytes(len);
        uint256 chunks = (len + 31) / 32;
        for (uint256 i; i < chunks; ++i) {
            bytes32 chunk = _tload(_autoRecBytesChunkSlot(i));
            assembly {
                mstore(add(result, add(0x20, mul(i, 32))), chunk)
            }
        }
    }

    /// @inheritdoc ISimulator
    function simulatedBundleHashAt(bytes32 _flowId, uint256 _index) external view returns (bytes32) {
        return _simulatedBundleHashes[_flowId][_index];
    }

    /// @inheritdoc ISimulator
    function simulatedBundleCount(bytes32 _flowId) external view returns (uint256) {
        return _simulatedBundleHashes[_flowId].length;
    }

    /// @inheritdoc ISimulator
    function isFlowSimulated(bytes32 _flowId) external view returns (bool) {
        return _flowSimulated[_flowId];
    }

    /// @inheritdoc ISimulator
    function isSimulating() external view returns (bool) {
        return _tload(_SIM_FLOW_ID_SLOT) != bytes32(0);
    }
}
