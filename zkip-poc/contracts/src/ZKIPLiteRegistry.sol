// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainBatchRootTree} from "era/common/libraries/ChainBatchRootTree.sol";
import {StoredInteropRoot} from "era/common/Messaging.sol";
import {ImtInsertion} from "./ImtInsertion.sol";
import {MockCaps} from "./mocks/MockCaps.sol";
import {MockMessageRoot} from "./mocks/MockMessageRoot.sol";
import {
    BatchNotProven,
    BatchRootMismatch,
    ImtContinuity,
    ImtEndMismatch,
    InvalidProof,
    NotTheChain,
    NoVerifier,
    OnlyOwner,
    TooManyChains,
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

/// @notice ZKIP-lite registry and execute gate: verifies the chains' debit and claim proofs and gates the execution
/// of batches that appended interop legs. The design is described in zkip-poc/README.md.
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
        uint256[] commitValues;
        ImtInsertion.Proof[] inserts;
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

    address public immutable owner;
    MockMessageRoot public immutable messageRoot;
    MockCaps public immutable caps;

    mapping(uint256 maxLegs => IHonkVerifier) public debitVerifier;
    mapping(uint256 maxCredits => IHonkVerifier) public claimVerifier;
    uint256[MAX_ZKIP_CHAINS] public zkipChains;
    uint256 public zkipChainCount;
    mapping(uint256 chainId => ChainState) public chains;
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 imtTransition)) public provenBatch;

    event ChainEnabled(uint256 indexed chainId, bytes32 stateRoot);
    event DebitProven(uint256 indexed chainId, uint256 indexed batchNumber, uint256 legs, bytes32 newStateRoot);
    event ClaimProven(uint256 indexed chainId, uint256 credits, bytes32 newStateRoot);
    event BatchGated(uint256 indexed chainId, uint256 indexed batchNumber, bool hadLegs);

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
        uint256 size = _s.commitValues.length <= DEBIT_SMALL ? DEBIT_SMALL : DEBIT_LARGE;
        (bytes32[] memory pi, bytes32 imtRoot, uint256 leafCount) = _debitInputs(_s, size);
        _verify(debitVerifier[size], _s.proof, pi);
        _applyDebit(_s, imtRoot, leafCount);
    }

    /// @notice Credits final legs to the chain and optionally unlocks value to its public cap.
    /// @param _s The claim and its proof.
    function submitClaim(ClaimSubmission calldata _s) external {
        uint256 size = _s.numCredits <= CLAIM_SMALL ? CLAIM_SMALL : CLAIM_LARGE;
        bytes32[] memory pi = _claimInputs(_s, size);
        _verify(claimVerifier[size], _s.proof, pi);
        _applyClaim(_s);
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
        _checkBatchRoot(c, _batchNumber, _cbr);
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

    /// @notice The L1 checks of a debit, and the public inputs its circuit of `_size` legs was proven against.
    function _debitInputs(
        DebitSubmission calldata _s,
        uint256 _size
    ) internal view returns (bytes32[] memory pi, bytes32 imtRoot, uint256 leafCount) {
        ChainState storage c = _chain(_s.chainId);
        _checkBatchRoot(c, _s.batchNumber, _s.cbr);
        require(_s.cbr.imtBegin == c.provenImtRoot, ImtContinuity(c.provenImtRoot, _s.cbr.imtBegin));
        uint256 legs = _s.commitValues.length;
        require(legs >= 1 && legs <= _size && _s.inserts.length == legs, NoVerifier(legs));

        imtRoot = _s.cbr.imtBegin;
        leafCount = c.provenImtLeafCount;
        for (uint256 i = 0; i < legs; ++i) {
            imtRoot = ImtInsertion.applyInsert(imtRoot, leafCount++, _s.commitValues[i], _s.inserts[i]);
        }
        require(imtRoot == _s.cbr.imtEnd, ImtEndMismatch());

        pi = new bytes32[](8 + 2 * _size);
        pi[0] = bytes32(_s.chainId);
        pi[1] = bytes32(block.chainid);
        pi[2] = c.stateRoot;
        pi[3] = _s.newStateRoot;
        pi[4] = bytes32(legs);
        for (uint256 i = 0; i < legs; ++i) {
            (pi[5 + i], pi[5 + _size + i]) = _split(bytes32(_s.commitValues[i]));
        }
        (pi[5 + 2 * _size], pi[6 + 2 * _size]) = _split(_s.lockAssetId);
        pi[7 + 2 * _size] = bytes32(_s.lockAmount);
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
        emit DebitProven(_s.chainId, _s.batchNumber, _s.commitValues.length, _s.newStateRoot);
    }

    /// @notice The public inputs a claim circuit of `_size` credits was proven against.
    function _claimInputs(ClaimSubmission calldata _s, uint256 _size) internal view returns (bytes32[] memory pi) {
        ChainState storage c = _chain(_s.chainId);
        require(_s.numCredits >= 1 && _s.numCredits <= _size, NoVerifier(_s.numCredits));
        pi = new bytes32[](CLAIM_PUBLIC_INPUTS);
        pi[0] = bytes32(_s.chainId);
        pi[1] = bytes32(block.chainid);
        pi[2] = c.stateRoot;
        pi[3] = _s.newStateRoot;
        pi[4] = bytes32(_s.numCredits);
        for (uint256 i = 0; i < ANCHORS; ++i) {
            StoredInteropRoot memory anchor = messageRoot.historicalRoot(_s.anchorBlocks[i]);
            require(anchor.root != bytes32(0), UnknownAnchor(_s.anchorBlocks[i]));
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

    function _chain(uint256 _chainId) internal view returns (ChainState storage c) {
        c = chains[_chainId];
        require(c.chain != address(0), UnknownChain(_chainId));
    }

    function _checkBatchRoot(
        ChainState storage _c,
        uint256 _batchNumber,
        ChainBatchRootPreimage calldata _cbr
    ) internal view {
        bytes32 computed = ChainBatchRootTree.compute(_cbr.logsRoot, _cbr.multichainRoot, _cbr.imtBegin, _cbr.imtEnd);
        require(computed == IChainBatches(_c.chain).committedRoot(_batchNumber), BatchRootMismatch());
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
