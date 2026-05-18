// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Create2Address} from "./Create2Address.sol";
import {L1ShadowAccount} from "./L1ShadowAccount.sol";

/// @notice The Bridgehub L2-message-inclusion verification surface used here.
/// Mirrors the production interface — only the bits we need.
struct L2Message {
    uint16 txNumberInBatch;
    address sender;
    bytes data;
}

interface IBridgehub {
    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view returns (bool);
}

/// @notice On-chain mirror of the L2 InteropCenter's bundle structures.
/// Field layout matches the `InteropBundleSent` event so the bundle bytes
/// emitted by the L2 InteropCenter can be `abi.decode(...)`'d here directly.
struct InteropCall {
    bytes1 version;
    bool shadowAccount;
    address to;
    address from;
    uint256 value;
    bytes data;
}

struct BundleAttributes {
    bytes executionAddress;
    bytes unbundlerAddress;
    bool useFixedFee;
}

struct InteropBundle {
    bytes1 version;
    uint256 sourceChainId;
    uint256 destinationChainId;
    bytes32 destinationBaseTokenAssetId;
    bytes32 interopBundleSalt;
    InteropCall[] calls;
    BundleAttributes bundleAttributes;
}

/// @notice L1-side interop handler — companion to the L2 InteropCenter.
///
/// Responsibilities (per kl/interop-docs/specs/design/l1-interop.md):
///   1. Accept a proof of an L2->L1 message that originated at the L2 InteropCenter.
///   2. Verify inclusion via the canonical Bridgehub.
///   3. Decode the message as an `InteropBundle`.
///   4. Lazy-deploy a per-(originChainId, fromAddress) `L1ShadowAccount` via CREATE2.
///   5. Execute each call. Calls flagged `shadowAccount=true` are routed through the
///      shadow account so msg.sender on the target == shadow account address.
///   6. Replay protection via `bundleStatus[bundleHash]`.
///
/// Structurally based on PR #2177's L1InteropHandler, but the bundle schema and
/// per-call shadowAccount flag follow the newer kl/interop-docs spec.
contract L1InteropHandler {
    enum Status { None, Executed }

    IBridgehub public immutable BRIDGE_HUB;
    /// @notice Address of the L2 InteropCenter system contract that may emit valid bundles.
    /// On a ZKsync OS chain this is fixed at the system-contract address (0x...0d).
    address public immutable L2_INTEROP_CENTER;
    /// @notice CREATE2 init-code hash of L1ShadowAccount, cached for cheap address derivation.
    bytes32 public immutable SHADOW_ACCOUNT_BYTECODE_HASH;

    /// @notice Bundle replay-protection. Keyed by `keccak256(message)` (== InteropBundleSent.l2l1MsgHash).
    mapping(bytes32 => Status) public bundleStatus;

    event ShadowAccountDeployed(uint256 indexed l2ChainId, address indexed l2Sender, address shadowAccount);
    event BundleExecuted(bytes32 indexed bundleMsgHash, uint256 indexed sourceChainId, uint256 callsExecuted);
    event CallExecuted(
        bytes32 indexed bundleMsgHash,
        uint256 indexed callIndex,
        address indexed via,
        address target,
        uint256 value,
        bool shadowAccount
    );

    error InvalidProof();
    error WrongL2Sender(address actualSender);
    error AlreadyExecuted();
    error WrongDestinationChain(uint256 expected, uint256 actual);
    error ShadowAccountDeploymentFailed();
    error CallFailed(uint256 callIndex, bytes returndata);

    constructor(address _bridgehub, address _l2InteropCenter) {
        BRIDGE_HUB = IBridgehub(_bridgehub);
        L2_INTEROP_CENTER = _l2InteropCenter;
        SHADOW_ACCOUNT_BYTECODE_HASH = keccak256(type(L1ShadowAccount).creationCode);
    }

    /// @notice Parameters carried in an L1 finalize call. Mirrors the FinalizeL1DepositParams
    /// shape used elsewhere in era-contracts so an off-chain finalizer can reuse the same
    /// proof RPC payloads.
    struct ExecuteBundleParams {
        uint256 chainId;
        uint256 l2BatchNumber;
        uint256 l2MessageIndex;
        uint16 l2TxNumberInBatch;
        address l2Sender;
        bytes message;
        bytes32[] merkleProof;
    }

    function executeBundle(ExecuteBundleParams calldata p) external payable returns (bytes32 bundleMsgHash) {
        // 1. Replay-protect on the message hash, which is what the Bridgehub authenticates.
        bundleMsgHash = keccak256(p.message);
        if (bundleStatus[bundleMsgHash] != Status.None) revert AlreadyExecuted();
        bundleStatus[bundleMsgHash] = Status.Executed;

        // 2. The InteropCenter is the only sender we accept.
        if (p.l2Sender != L2_INTEROP_CENTER) revert WrongL2Sender(p.l2Sender);

        // 3. Verify L2->L1 message inclusion against the canonical Bridgehub.
        bool ok = BRIDGE_HUB.proveL2MessageInclusion(
            p.chainId,
            p.l2BatchNumber,
            p.l2MessageIndex,
            L2Message({txNumberInBatch: p.l2TxNumberInBatch, sender: p.l2Sender, data: p.message}),
            p.merkleProof
        );
        if (!ok) revert InvalidProof();

        // 4. Decode the InteropBundle directly from the message bytes.
        InteropBundle memory bundle = abi.decode(p.message, (InteropBundle));

        if (bundle.destinationChainId != block.chainid) {
            revert WrongDestinationChain(block.chainid, bundle.destinationChainId);
        }

        // 5. Execute each call, optionally routing through the per-user shadow account.
        // For shadowAccount calls, the shadow account spends from its own balance —
        // ETH lands there via separate L2BaseToken.withdraw() bridges, NOT via this
        // handler. The handler holds no funds for users by design.
        uint256 n = bundle.calls.length;
        for (uint256 i = 0; i < n; ++i) {
            InteropCall memory c = bundle.calls[i];
            if (c.shadowAccount) {
                address sa = _ensureShadowAccount(bundle.sourceChainId, c.from);
                L1ShadowAccount(payable(sa)).executeFromHandler(c.to, c.value, c.data);
                emit CallExecuted(bundleMsgHash, i, sa, c.to, c.value, true);
            } else {
                (bool success, bytes memory ret) = c.to.call{value: c.value}(c.data);
                if (!success) revert CallFailed(i, ret);
                emit CallExecuted(bundleMsgHash, i, address(this), c.to, c.value, false);
            }
        }

        emit BundleExecuted(bundleMsgHash, bundle.sourceChainId, n);
    }

    /// @notice Returns the deterministic L1 shadow-account address for an L2 (chainId, sender) pair.
    /// Address can be precomputed off-chain or by the caller before any deposit.
    function shadowAccountFor(uint256 _l2ChainId, address _l2Sender) public view returns (address) {
        bytes32 salt = _shadowAccountSalt(_l2ChainId, _l2Sender);
        return Create2Address.getNewAddressCreate2EVM(address(this), salt, SHADOW_ACCOUNT_BYTECODE_HASH);
    }

    function _ensureShadowAccount(uint256 _l2ChainId, address _l2Sender) internal returns (address) {
        bytes32 salt = _shadowAccountSalt(_l2ChainId, _l2Sender);
        address predicted = Create2Address.getNewAddressCreate2EVM(address(this), salt, SHADOW_ACCOUNT_BYTECODE_HASH);
        if (predicted.code.length == 0) {
            L1ShadowAccount sa = new L1ShadowAccount{salt: salt}();
            if (address(sa) != predicted) revert ShadowAccountDeploymentFailed();
            emit ShadowAccountDeployed(_l2ChainId, _l2Sender, predicted);
        }
        return predicted;
    }

    function _shadowAccountSalt(uint256 _l2ChainId, address _l2Sender) internal pure returns (bytes32) {
        return keccak256(abi.encode(_l2ChainId, _l2Sender));
    }

    /// @notice Lets the handler hold ETH (e.g. user-prefunded value for non-shadow calls).
    receive() external payable {}
}
