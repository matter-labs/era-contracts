// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {InteropHandlerBase} from "./InteropHandlerBase.sol";

import {L2_INTEROP_CENTER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {BUNDLE_IDENTIFIER, BundleStatus, InteropBundle, MessageInclusionProof} from "../../common/Messaging.sol";
import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IMessageRootBase} from "../../core/message-root/IMessageRoot.sol";
import {InteropWithdrawalNonZeroValue} from "../../bridge/L1BridgeContractErrors.sol";
import {ZeroAddress} from "../../common/L1ContractErrors.sol";
import {
    InteropCallToL1NotToAssetRouter,
    MessageNotIncluded,
    MultiCallToL1NotSupported,
    UnauthorizedMessageSender
} from "../InteropErrors.sol";

/// @title L1InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L1-side interop handler. It finalizes L2 -> L1 interop bundles proven by L1 **message inclusion**
/// (`MessageInclusionProof`), symmetric to the L2 `L2InteropHandler` which instead proves atomic IMT finality.
/// For this release an L1-destined bundle is restricted to a single asset WITHDRAWAL: the L2 InteropCenter only
/// accepts an indirect, zero-value call to the L2 AssetRouter, which resolves to a call targeting the L1 asset
/// router's `finalizeDeposit`, delivered here via ERC-7786 `receiveMessage`. Arbitrary/direct L2 -> L1 calls are
/// not allowed, keeping the L1-side surface to the asset router.
/// @dev Deployed behind a proxy on L1.
/// @dev Pausable so that withdrawals can be halted: previously `L1Nullifier.finalizeDeposit` carried the
/// `whenNotPaused` gate for withdrawal finalization; that gate now lives here, on the call-executing entry
/// points (`executeBundle`/`unbundleBundle`) of the handler that replaced it.
contract L1InteropHandler is InteropHandlerBase, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @dev MessageRoot smart contract that is used to prove message inclusion.
    IMessageRootBase public immutable MESSAGE_ROOT;

    /// @dev The canonical L1 AssetRouter — the only recipient L1-destined bundles may target (see
    /// {_interopCallTarget}). Immutable, set at construction, to avoid resolving it on every execution.
    address public immutable L1_ASSET_ROUTER;

    /// @dev Contract is expected to be used as a proxy implementation.
    /// @dev Locking the reentrancy guard (and disabling the OZ initializers) in the constructor prevents the
    /// implementation from being initialized.
    /// @param _messageRoot The MessageRoot used to prove message inclusion.
    /// @param _l1AssetRouter The canonical L1 AssetRouter (the only supported L1 bundle-call target).
    constructor(IMessageRootBase _messageRoot, address _l1AssetRouter) reentrancyGuardInitializer {
        _disableInitializers();
        require(_l1AssetRouter != address(0), ZeroAddress());
        MESSAGE_ROOT = _messageRoot;
        L1_ASSET_ROUTER = _l1AssetRouter;
    }

    /// @notice Initializes the contract behind its proxy.
    /// @param _owner The owner that can pause/unpause withdrawal processing.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        _transferOwnership(_owner);
    }

    /// @notice Pauses bundle execution/unbundling — i.e. halts L2 -> L1 withdrawal finalization.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes bundle execution/unbundling.
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                Message-inclusion execution / verification
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalizes an L2 -> L1 bundle proven by L1 message inclusion.
    /// @param _bundle ABI-encoded InteropBundle to execute.
    /// @param _proof Inclusion proof for the `BUNDLE_IDENTIFIER`-prefixed bundle message.
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public {
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        // An L1-destined bundle is a single asset withdrawal (enforced at send); re-assert as defense-in-depth.
        require(interopBundle.calls.length == 1, MultiCallToL1NotSupported(interopBundle.calls.length));

        // Shared pre-gate validation (pause/permission/executability).
        _validateExecutable(bundleHash, interopBundle, status);

        // Proof gate (if not yet verified). `_verifyBundle` also runs the destination-context / fresh-bundle
        // check; an already-`Verified` bundle had it checked at verify time, and it's invariant per bundle.
        if (status != BundleStatus.Verified) {
            // solhint-disable-next-line func-named-parameters
            _verifyBundle(_bundle, interopBundle, _proof, bundleHash, status);
        }

        _markFullyExecutedAndRun(bundleHash, interopBundle);
    }

    /// @notice Verifies receipt of an L2 -> L1 bundle without executing its calls.
    /// @param _bundle ABI-encoded InteropBundle to verify.
    /// @param _proof Inclusion proof for the `BUNDLE_IDENTIFIER`-prefixed bundle message.
    function verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public {
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        // `_verifyBundle` runs `_validateVerifiable` (destination-context + fresh-bundle) then the message-
        // inclusion proof gate, and marks the bundle `Verified`.
        // solhint-disable-next-line func-named-parameters
        _verifyBundle(_bundle, interopBundle, _proof, bundleHash, status);
    }

    /*//////////////////////////////////////////////////////////////
                    receiveMessage dispatch hooks
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc InteropHandlerBase
    function _executeBundleSelector() internal view override returns (bytes4) {
        return this.executeBundle.selector;
    }

    /// @inheritdoc InteropHandlerBase
    function _verifyBundleSelector() internal view override returns (bytes4) {
        return this.verifyBundle.selector;
    }

    /// @inheritdoc InteropHandlerBase
    function _receiveExecuteBundle(
        bytes calldata _payload,
        uint256 _senderChainId,
        address _senderAddress,
        bytes calldata _sender
    ) internal override {
        (bytes memory bundle, MessageInclusionProof memory proof) = abi.decode(
            _payload[4:],
            (bytes, MessageInclusionProof)
        );

        // Enforce the bundle's execution-address permission against the wrapped message's sender.
        (InteropBundle memory interopBundle, bytes32 bundleHash, ) = _getBundleData(bundle);
        _requireRescueExecutionAllowed({
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _senderChainId: _senderChainId,
            _senderAddress: _senderAddress,
            _sender: _sender
        });

        this.executeBundle(bundle, proof);
    }

    /// @inheritdoc InteropHandlerBase
    function _receiveVerifyBundle(bytes calldata _payload) internal override {
        (bytes memory bundle, MessageInclusionProof memory proof) = abi.decode(
            _payload[4:],
            (bytes, MessageInclusionProof)
        );

        // Bundle verification is permissionless
        this.verifyBundle(bundle, proof);
    }

    /*//////////////////////////////////////////////////////////////
                        Environment-specific hooks
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc InteropHandlerBase
    /// @dev Blocks `executeBundle`/`unbundleBundle` while paused, halting withdrawal finalization.
    function _ensureNotPaused() internal view override {
        _requireNotPaused();
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev L1-destined calls carry no base-token call value; any transferred amount rides inside the call
    /// payload (e.g. a withdrawal's `finalizeDeposit` transfer data).
    /// @dev Deliberate double-defense: the same invariant is already enforced at SEND time by the L2
    /// InteropCenter (`NonZeroValueToL1NotSupported`); this receive-side check re-verifies it with its own
    /// error (`InteropWithdrawalNonZeroValue`) in case a malformed bundle ever reaches L1.
    function _handleCallValue(uint256 _value, uint256 /* _sourceChainId */) internal pure override {
        require(_value == 0, InteropWithdrawalNonZeroValue(_value));
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev On L1 the base token is ETH; bundles destined for L1 carry L1's ETH asset ID.
    function _expectedDestinationBaseTokenAssetId() internal view override returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev Pins the target to the canonical L1 AssetRouter regardless of `_to`, confining the L1 execution
    /// surface to its `finalizeDeposit` path (whose `receiveMessage` validates selector/sender/source-chain).
    /// A well-formed withdrawal already carries `_to == L1_ASSET_ROUTER`; anything else reverts.
    function _interopCallTarget(address _to) internal view override returns (address) {
        require(_to == L1_ASSET_ROUTER, InteropCallToL1NotToAssetRouter(_to));
        return L1_ASSET_ROUTER;
    }

    /// @notice Verifies the bundle: runs the shared destination-context / fresh-bundle validation, then checks
    /// that its `BUNDLE_IDENTIFIER`-prefixed message was included, sent by the canonical L2 InteropCenter. Asset
    /// correctness across chains is guaranteed by ZK proofs, so no on-chain per-chain balance reconciliation is
    /// performed here.
    /// @param _bundle The abi-encoded InteropBundle struct to verify.
    /// @param _interopBundle The decoded bundle (for the destination-context validation).
    /// @param _proof Proof for the message corresponding to the bundle.
    /// @param _bundleHash Hash corresponding to the bundle.
    /// @param _status Current bundle status (must be `Unreceived`).
    function _verifyBundle(
        bytes memory _bundle,
        InteropBundle memory _interopBundle,
        MessageInclusionProof memory _proof,
        bytes32 _bundleHash,
        BundleStatus _status
    ) internal {
        // Destination-context + fresh-bundle gate. Single home for the context check (see {_validateExecutable}).
        _validateVerifiable(_bundleHash, _interopBundle, _proof.chainId, _status);

        require(
            _proof.message.sender == L2_INTEROP_CENTER_ADDR,
            UnauthorizedMessageSender(L2_INTEROP_CENTER_ADDR, _proof.message.sender)
        );

        // Substitute provided message data with data corresponding to the bundle currently being verified.
        _proof.message.data = bytes.concat(BUNDLE_IDENTIFIER, _bundle);

        require(_proveInclusion(_proof), MessageNotIncluded());

        _markVerified(_bundleHash);
    }

    /// @dev Proves the bundle's inclusion via the L1 MessageRoot.
    function _proveInclusion(MessageInclusionProof memory _proof) internal view returns (bool) {
        return
            MESSAGE_ROOT.proveL2MessageInclusionShared({
                _chainId: _proof.chainId,
                _blockOrBatchNumber: _proof.l1BatchNumber,
                _index: _proof.l2MessageIndex,
                _message: _proof.message,
                _proof: _proof.proof
            });
    }
}
