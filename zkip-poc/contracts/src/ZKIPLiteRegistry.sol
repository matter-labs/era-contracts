// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainBatchRootTree} from "era/common/libraries/ChainBatchRootTree.sol";
import {StoredInteropRoot} from "era/common/Messaging.sol";
import {MockCaps} from "./mocks/MockCaps.sol";
import {MockMessageRoot} from "./mocks/MockMessageRoot.sol";
import {revertWith} from "./RevertWith.sol";
import {DEBIT_1_CIRCUIT_ID} from "./ZKIPLiteConfig.sol";
import {
    BadAggregate,
    BatchNotProven,
    BatchRootMismatch,
    CapExceeded,
    ImtContinuity,
    InvalidProof,
    NotTheChain,
    NoVerifier,
    OnlyOwner,
    SlotInputsMismatch,
    TooManyChains,
    UnapprovedCircuit,
    UnknownAnchor,
    UnknownChain
} from "./ZKIPLiteErrors.sol";

/// @notice bb's generated UltraHonk Solidity verifier.
interface IHonkVerifier {
    function verify(bytes calldata _proof, bytes32[] calldata _publicInputs) external view returns (bool);
}

/// @notice The committed batch roots of a chain (stand-in for the diamond's stored batch data).
interface IChainBatches {
    function committedRoot(uint256 _batchNumber) external view returns (bytes32);
}

/// @notice ZKIP-lite registry and execute gate: verifies the chains' debit and claim proofs, one by one or several in
/// one aggregated proof, and gates the execution of batches that appended interop legs. The design is described in
/// zkip-poc/README.md.
contract ZKIPLiteRegistry {
    /// @notice The four leaves of a chain batch root.
    struct ChainBatchRootPreimage {
        bytes32 logsRoot;
        bytes32 multichainRoot;
        bytes32 imtBegin;
        bytes32 imtEnd;
    }

    /// @notice A debit of every leg one committed batch appended to the chain's interop commitment tree.
    struct DebitSubmission {
        uint256 chainId;
        uint256 batchNumber;
        ChainBatchRootPreimage cbr;
        uint256 numLegs;
        bytes32 lockAssetId;
        uint256 lockAmount;
        bytes32 newStateRoot;
        bytes proof;
    }

    /// @notice A credit of up to two final legs to the chain, with an optional unlock to its public cap.
    struct ClaimSubmission {
        uint256 chainId;
        uint256 numCredits;
        uint256[2] anchorBlocks;
        bytes32 unlockAssetId;
        uint256 unlockAmount;
        bytes32 newStateRoot;
        bytes proof;
    }

    /// @notice One agg_4 proof and the L1 data of the statements in its slots.
    /// @dev `publicInputs` is agg_4's public input vector: each slot's 16 inner public inputs, then each slot's VK
    /// commitment. Debit and claim slots take their data from `debits` and `claims` in slot order, with `proof` empty.
    struct AggregatedSubmission {
        bytes proof;
        bytes32[] publicInputs;
        uint8[] kinds;
        DebitSubmission[] debits;
        ClaimSubmission[] claims;
    }

    struct ChainState {
        address chain;
        bytes32 stateRoot;
        bytes32 provenImtRoot;
        uint256 provenImtLeafCount;
        bytes32 executedImtRoot;
    }

    uint256 internal constant MAX_ZKIP_CHAINS = 4;
    uint256 internal constant DEBIT_SMALL = 1;
    uint256 internal constant DEBIT_LARGE = 4;
    uint256 internal constant CLAIM_SMALL = 1;
    uint256 internal constant CLAIM_LARGE = 2;
    uint256 internal constant CLAIM_PUBLIC_INPUTS = 16;
    uint256 internal constant ANCHORS = 2;
    uint256 internal constant AGG_SLOTS = 4;
    uint256 internal constant AGG_SLOT_INPUTS = 16;
    uint8 internal constant SLOT_UNUSED = 0;
    uint8 internal constant SLOT_DEBIT = 1;
    uint8 internal constant SLOT_CLAIM = 2;

    /// @notice Values of `aggCircuit`: the circuit a VK commitment belongs to.
    uint256 public constant CIRCUIT_DEBIT_4 = 1004;
    uint256 public constant CIRCUIT_DEBIT_1 = DEBIT_1_CIRCUIT_ID;
    uint256 public constant CIRCUIT_CLAIM_1 = 2001;
    uint256 public constant CIRCUIT_CLAIM_2 = 2002;

    address public immutable owner;
    MockMessageRoot public immutable messageRoot;
    MockCaps public immutable caps;

    mapping(uint256 maxLegs => IHonkVerifier) public debitVerifier;
    mapping(uint256 maxCredits => IHonkVerifier) public claimVerifier;
    uint256[MAX_ZKIP_CHAINS] public zkipChains;
    uint256 public zkipChainCount;
    mapping(uint256 chainId => ChainState) public chains;
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 imtTransition)) public provenBatch;
    IHonkVerifier public aggVerifier;
    mapping(bytes32 vkCommitment => uint256 circuit) public aggCircuit;

    event ChainEnabled(uint256 indexed chainId, bytes32 stateRoot);
    event DebitProven(uint256 indexed chainId, uint256 indexed batchNumber, uint256 legs, bytes32 newStateRoot);
    event ClaimProven(uint256 indexed chainId, uint256 credits, bytes32 newStateRoot);
    event BatchGated(uint256 indexed chainId, uint256 indexed batchNumber, bool hadLegs);
    event SlotSkipped(uint256 indexed slot, uint8 kind, bytes reason);

    /// @param _messageRoot The message root whose historical roots anchor claims.
    /// @param _caps The per-chain public caps that locks and unlocks move value against.
    constructor(MockMessageRoot _messageRoot, MockCaps _caps) {
        owner = msg.sender;
        messageRoot = _messageRoot;
        caps = _caps;
    }

    /// @notice Sets the verifiers per size class.
    /// @param _debitSizes Max legs of each debit circuit.
    /// @param _debit The debit verifiers, in `_debitSizes` order.
    /// @param _claimSizes Max credits of each claim circuit.
    /// @param _claim The claim verifiers, in `_claimSizes` order.
    function setVerifiers(
        uint256[] calldata _debitSizes,
        IHonkVerifier[] calldata _debit,
        uint256[] calldata _claimSizes,
        IHonkVerifier[] calldata _claim
    ) external {
        require(msg.sender == owner, OnlyOwner());
        for (uint256 i = 0; i < _debitSizes.length; ++i) {
            debitVerifier[_debitSizes[i]] = _debit[i];
        }
        for (uint256 i = 0; i < _claimSizes.length; ++i) {
            claimVerifier[_claimSizes[i]] = _claim[i];
        }
    }

    /// @notice Sets the agg_4 verifier and the circuits its slots may carry.
    /// @param _verifier The agg_4 verifier.
    /// @param _vkCommitments VK commitments of the inner circuits.
    /// @param _circuits The CIRCUIT_* value of each commitment; 0 revokes it.
    function setAggregation(
        IHonkVerifier _verifier,
        bytes32[] calldata _vkCommitments,
        uint256[] calldata _circuits
    ) external {
        require(msg.sender == owner, OnlyOwner());
        aggVerifier = _verifier;
        for (uint256 i = 0; i < _vkCommitments.length; ++i) {
            aggCircuit[_vkCommitments[i]] = _circuits[i];
        }
    }

    /// @notice Makes a fresh chain a ZKIP chain (owner-only, one-way).
    /// @param _chainId The chain id.
    /// @param _chain The chain's contract (batch roots, execute gate caller).
    /// @param _initialStateRoot The root of an empty ZKIP state.
    function enableChain(uint256 _chainId, address _chain, bytes32 _initialStateRoot) external {
        require(msg.sender == owner, OnlyOwner());
        require(zkipChainCount < MAX_ZKIP_CHAINS, TooManyChains());
        zkipChains[zkipChainCount++] = _chainId;
        chains[_chainId] = ChainState({
            chain: _chain,
            stateRoot: _initialStateRoot,
            provenImtRoot: ChainBatchRootTree.EMPTY_IMT_ROOT,
            provenImtLeafCount: 1,
            executedImtRoot: ChainBatchRootTree.EMPTY_IMT_ROOT
        });
        emit ChainEnabled(_chainId, _initialStateRoot);
    }

    /// @notice Proves the debit of every leg a committed batch appended to the chain's IMT.
    /// @param _s The debit and its proof.
    function submitDebit(DebitSubmission calldata _s) external {
        uint256 size = _s.numLegs <= DEBIT_SMALL ? DEBIT_SMALL : DEBIT_LARGE;
        (bytes memory err, bytes32[] memory pi, bytes32 imtRoot, uint256 leafCount) = _checkDebit(_s, size);
        if (err.length != 0) {
            revertWith(err);
        }
        _verify(debitVerifier[size], _s.proof, pi);
        _applyDebit(_s, imtRoot, leafCount);
    }

    /// @notice Credits final legs to the chain and optionally unlocks value to its public cap.
    /// @param _s The claim and its proof.
    function submitClaim(ClaimSubmission calldata _s) external {
        uint256 size = _s.numCredits <= CLAIM_SMALL ? CLAIM_SMALL : CLAIM_LARGE;
        (bytes memory err, bytes32[] memory pi) = _checkClaim(_s, size);
        if (err.length != 0) {
            revertWith(err);
        }
        _verify(claimVerifier[size], _s.proof, pi);
        _applyClaim(_s);
    }

    /// @notice Applies, in slot order, the statements of one aggregated proof from any ZKIP chains. Anyone may submit.
    /// @dev A slot whose circuit isn't approved for its kind, or whose public inputs aren't what L1 would hand that
    /// circuit now (e.g. its chain proved the batch directly meanwhile), is skipped with `SlotSkipped`.
    /// @param _s The aggregated proof and its slots' data.
    function submitAggregated(AggregatedSubmission calldata _s) external {
        require(
            _s.kinds.length == AGG_SLOTS && _s.publicInputs.length == AGG_SLOTS * (AGG_SLOT_INPUTS + 1),
            BadAggregate()
        );
        _verify(aggVerifier, _s.proof, _s.publicInputs);
        uint256 nextDebit;
        uint256 nextClaim;
        for (uint256 i = 0; i < AGG_SLOTS; ++i) {
            uint8 kind = _s.kinds[i];
            if (kind == SLOT_UNUSED) {
                continue;
            }
            bytes32[] calldata pi = _s.publicInputs[i * AGG_SLOT_INPUTS:(i + 1) * AGG_SLOT_INPUTS];
            bytes32 vkCommitment = _s.publicInputs[AGG_SLOTS * AGG_SLOT_INPUTS + i];
            bytes memory skipped;
            if (kind == SLOT_DEBIT) {
                skipped = _aggregatedDebit(_s.debits[nextDebit++], vkCommitment, pi);
            } else if (kind == SLOT_CLAIM) {
                skipped = _aggregatedClaim(_s.claims[nextClaim++], vkCommitment, pi);
            } else {
                revert BadAggregate();
            }
            if (skipped.length != 0) {
                emit SlotSkipped(i, kind, skipped);
            }
        }
    }

    /// @notice The execute gate: a batch that appended legs executes only once its debit is proven.
    /// @param _chainId The chain id.
    /// @param _batchNumber The batch being executed.
    /// @param _cbr The batch's chain batch root preimage.
    function onExecute(uint256 _chainId, uint256 _batchNumber, ChainBatchRootPreimage calldata _cbr) external {
        ChainState storage c = chains[_chainId];
        if (c.chain == address(0)) {
            return;
        }
        require(msg.sender == c.chain, NotTheChain());
        require(_batchRootMatches(c, _batchNumber, _cbr), BatchRootMismatch());
        require(_cbr.imtBegin == c.executedImtRoot, ImtContinuity(c.executedImtRoot, _cbr.imtBegin));
        bool hadLegs = _cbr.imtBegin != _cbr.imtEnd;
        if (hadLegs) {
            require(
                provenBatch[_chainId][_batchNumber] == keccak256(abi.encode(_cbr.imtBegin, _cbr.imtEnd)),
                BatchNotProven(_chainId, _batchNumber)
            );
        }
        c.executedImtRoot = _cbr.imtEnd;
        emit BatchGated(_chainId, _batchNumber, hadLegs);
    }

    /// @notice Applies one aggregated debit if its circuit is approved and its public inputs are current.
    /// @return err Why the slot was skipped; empty if it was applied.
    function _aggregatedDebit(
        DebitSubmission calldata _d,
        bytes32 _vkCommitment,
        bytes32[] calldata _pi
    ) internal returns (bytes memory err) {
        uint256 circuit = aggCircuit[_vkCommitment];
        if (circuit != CIRCUIT_DEBIT_1 && circuit != CIRCUIT_DEBIT_4) {
            return abi.encodeWithSelector(UnapprovedCircuit.selector, _vkCommitment);
        }
        bytes32[] memory pi;
        bytes32 imtRoot;
        uint256 leafCount;
        (err, pi, imtRoot, leafCount) = _checkDebit(_d, circuit == CIRCUIT_DEBIT_1 ? DEBIT_SMALL : DEBIT_LARGE);
        if (err.length == 0 && keccak256(abi.encodePacked(pi)) != keccak256(abi.encodePacked(_pi))) {
            err = abi.encodeWithSelector(SlotInputsMismatch.selector);
        }
        if (err.length == 0) {
            _applyDebit(_d, imtRoot, leafCount);
        }
    }

    /// @notice Applies one aggregated claim if its circuit is approved and its public inputs are current.
    /// @return err Why the slot was skipped; empty if it was applied.
    function _aggregatedClaim(
        ClaimSubmission calldata _c,
        bytes32 _vkCommitment,
        bytes32[] calldata _pi
    ) internal returns (bytes memory err) {
        uint256 size = _c.numCredits <= CLAIM_SMALL ? CLAIM_SMALL : CLAIM_LARGE;
        if (aggCircuit[_vkCommitment] != (size == CLAIM_SMALL ? CIRCUIT_CLAIM_1 : CIRCUIT_CLAIM_2)) {
            return abi.encodeWithSelector(UnapprovedCircuit.selector, _vkCommitment);
        }
        bytes32[] memory pi;
        (err, pi) = _checkClaim(_c, size);
        if (err.length == 0 && keccak256(abi.encodePacked(pi)) != keccak256(abi.encodePacked(_pi))) {
            err = abi.encodeWithSelector(SlotInputsMismatch.selector);
        }
        if (err.length == 0) {
            _applyClaim(_c);
        }
    }

    /// @notice The L1 checks of a debit, and the public inputs its circuit of `_size` legs was proven against.
    /// @return err The encoded error of the first failed check; empty if all passed.
    function _checkDebit(
        DebitSubmission calldata _s,
        uint256 _size
    ) internal view returns (bytes memory err, bytes32[] memory pi, bytes32 imtRoot, uint256 leafCount) {
        ChainState storage c = chains[_s.chainId];
        if (c.chain == address(0)) {
            return (abi.encodeWithSelector(UnknownChain.selector, _s.chainId), pi, imtRoot, leafCount);
        }
        if (!_batchRootMatches(c, _s.batchNumber, _s.cbr)) {
            return (abi.encodeWithSelector(BatchRootMismatch.selector), pi, imtRoot, leafCount);
        }
        if (_s.cbr.imtBegin != c.provenImtRoot) {
            err = abi.encodeWithSelector(ImtContinuity.selector, c.provenImtRoot, _s.cbr.imtBegin);
            return (err, pi, imtRoot, leafCount);
        }
        uint256 legs = _s.numLegs;
        if (legs == 0 || legs > _size) {
            return (abi.encodeWithSelector(NoVerifier.selector, legs), pi, imtRoot, leafCount);
        }
        // ZKIP proves the complete insertion sequence between these batch-authenticated roots.
        imtRoot = _s.cbr.imtEnd;
        leafCount = c.provenImtLeafCount + legs;
        if (_s.lockAmount != 0) {
            uint256 cap = caps.cap(_s.chainId, _s.lockAssetId);
            if (cap < _s.lockAmount) {
                err = abi.encodeWithSelector(CapExceeded.selector, _s.chainId, _s.lockAssetId, cap, _s.lockAmount);
                return (err, pi, imtRoot, leafCount);
            }
        }
        pi = _debitPublicInputs(c, _s);
    }

    function _debitPublicInputs(
        ChainState storage _c,
        DebitSubmission calldata _s
    ) internal view returns (bytes32[] memory pi) {
        pi = new bytes32[](AGG_SLOT_INPUTS);
        pi[0] = bytes32(_s.chainId);
        pi[1] = bytes32(block.chainid);
        pi[2] = _c.stateRoot;
        pi[3] = _s.newStateRoot;
        pi[4] = bytes32(_s.numLegs);
        (pi[5], pi[6]) = _split(_s.cbr.imtBegin);
        (pi[7], pi[8]) = _split(_s.cbr.imtEnd);
        pi[9] = bytes32(_c.provenImtLeafCount);
        (pi[10], pi[11]) = _split(_s.lockAssetId);
        pi[12] = bytes32(_s.lockAmount);
    }

    function _applyDebit(DebitSubmission calldata _s, bytes32 _imtRoot, uint256 _leafCount) internal {
        ChainState storage c = chains[_s.chainId];
        if (_s.lockAmount != 0) {
            caps.lock(_s.chainId, _s.lockAssetId, _s.lockAmount);
        }
        c.stateRoot = _s.newStateRoot;
        c.provenImtRoot = _imtRoot;
        c.provenImtLeafCount = _leafCount;
        provenBatch[_s.chainId][_s.batchNumber] = keccak256(abi.encode(_s.cbr.imtBegin, _s.cbr.imtEnd));
        emit DebitProven(_s.chainId, _s.batchNumber, _s.numLegs, _s.newStateRoot);
    }

    /// @notice The L1 checks of a claim, and the public inputs its circuit of `_size` credits was proven against.
    /// @return err The encoded error of the first failed check; empty if all passed.
    function _checkClaim(
        ClaimSubmission calldata _s,
        uint256 _size
    ) internal view returns (bytes memory err, bytes32[] memory pi) {
        ChainState storage c = chains[_s.chainId];
        if (c.chain == address(0)) {
            return (abi.encodeWithSelector(UnknownChain.selector, _s.chainId), pi);
        }
        if (_s.numCredits == 0 || _s.numCredits > _size) {
            return (abi.encodeWithSelector(NoVerifier.selector, _s.numCredits), pi);
        }
        pi = new bytes32[](CLAIM_PUBLIC_INPUTS);
        pi[0] = bytes32(_s.chainId);
        pi[1] = bytes32(block.chainid);
        pi[2] = c.stateRoot;
        pi[3] = _s.newStateRoot;
        pi[4] = bytes32(_s.numCredits);
        for (uint256 i = 0; i < ANCHORS; ++i) {
            StoredInteropRoot memory anchor = messageRoot.historicalRoot(_s.anchorBlocks[i]);
            if (anchor.root == bytes32(0)) {
                return (abi.encodeWithSelector(UnknownAnchor.selector, _s.anchorBlocks[i]), pi);
            }
            (pi[5 + i], pi[7 + i]) = _split(anchor.root);
        }
        for (uint256 i = 0; i < MAX_ZKIP_CHAINS; ++i) {
            pi[9 + i] = bytes32(zkipChains[i]);
        }
        (pi[13], pi[14]) = _split(_s.unlockAssetId);
        pi[15] = bytes32(_s.unlockAmount);
    }

    function _applyClaim(ClaimSubmission calldata _s) internal {
        if (_s.unlockAmount != 0) {
            caps.unlock(_s.chainId, _s.unlockAssetId, _s.unlockAmount);
        }
        chains[_s.chainId].stateRoot = _s.newStateRoot;
        emit ClaimProven(_s.chainId, _s.numCredits, _s.newStateRoot);
    }

    function _batchRootMatches(
        ChainState storage _c,
        uint256 _batchNumber,
        ChainBatchRootPreimage calldata _cbr
    ) internal view returns (bool) {
        bytes32 computed = ChainBatchRootTree.compute(_cbr.logsRoot, _cbr.multichainRoot, _cbr.imtBegin, _cbr.imtEnd);
        return computed == IChainBatches(_c.chain).committedRoot(_batchNumber);
    }

    function _verify(IHonkVerifier _verifier, bytes calldata _proof, bytes32[] memory _pi) internal view {
        require(address(_verifier) != address(0), NoVerifier(0));
        require(_verifier.verify(_proof, _pi), InvalidProof());
    }

    /// @notice Splits a 32-byte word into its high and low 128-bit halves (field elements in the circuits).
    function _split(bytes32 _word) internal pure returns (bytes32 hi, bytes32 lo) {
        hi = bytes32(uint256(_word) >> 128);
        lo = bytes32(uint256(_word) & type(uint128).max);
    }
}
