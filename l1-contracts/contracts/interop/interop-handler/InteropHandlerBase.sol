// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.24;

import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";

import {L2_INTEROP_CENTER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {IInteropHandlerBase} from "./IInteropHandlerBase.sol";
import {
    BUNDLE_IDENTIFIER,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    BundleStatus,
    CallStatus,
    InteropBundle,
    InteropCall,
    MessageInclusionProof
} from "../../common/Messaging.sol";
import {IERC7786Recipient} from "../IERC7786Recipient.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {InteropDataEncoding} from "../InteropDataEncoding.sol";
import {
    BundleAlreadyProcessed,
    CallAlreadyExecuted,
    CallNotExecutable,
    CanNotUnbundle,
    EmptyBundle,
    ExecutingNotAllowed,
    MessageNotIncluded,
    UnauthorizedMessageSender,
    UnbundlingNotAllowed,
    WrongCallStatusLength,
    WrongDestinationChainId,
    WrongDestinationBaseTokenAssetId,
    WrongSourceChainId,
    InvalidInteropBundleVersion,
    InvalidInteropCallVersion
} from "../InteropErrors.sol";
import {InvalidSelector, PayloadTooShort, Unauthorized} from "../../common/L1ContractErrors.sol";

/// @title InteropHandlerBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Shared logic for executing, verifying and unbundling interop bundles. `L2InteropHandler` and
/// `L1InteropHandler` inherit this base and provide the environment-specific behaviour via the virtual
/// hooks below. See {protocol-docs/interop.md} (destination-side processing).
abstract contract InteropHandlerBase is IInteropHandlerBase, IERC7786Recipient, ReentrancyGuard {
    /// @dev Deprecated. This slot previously held the L1 chain id, which is no longer used (the handler operates
    /// on `block.chainid`). Retained — not removed — to preserve the upgradeable storage layout.
    // slither-disable-next-line uninitialized-state
    uint256 internal __DEPRECATED_L1_CHAIN_ID;

    /// @inheritdoc IInteropHandlerBase
    mapping(bytes32 bundleHash => BundleStatus bundleStatus) public bundleStatus;

    /// @inheritdoc IInteropHandlerBase
    mapping(bytes32 bundleHash => mapping(uint256 callIndex => CallStatus callStatus)) public callStatus;

    /*//////////////////////////////////////////////////////////////
                        Environment-specific hooks
    //////////////////////////////////////////////////////////////*/

    /// @notice Proves that the bundle message was included on the source chain.
    /// @dev L2 uses the `L2_MESSAGE_VERIFICATION` system contract; L1 uses the `MessageRoot`.
    function _proveInclusion(MessageInclusionProof memory _proof) internal view virtual returns (bool);

    /// @notice Handles the base-token value that rides along an interop call before it is forwarded.
    /// @dev L2 pulls the value from the `BaseTokenHolder`; L1 forbids non-zero value (withdrawals carry the amount in
    /// their transfer data, not as call value).
    function _handleCallValue(uint256 _value, uint256 _sourceChainId) internal virtual;

    /// @notice The base-token asset ID expected as the bundle's destination base token on this layer.
    function _expectedDestinationBaseTokenAssetId() internal view virtual returns (bytes32);

    /// @notice Guard invoked by the call-executing entry points (`executeBundle` and `unbundleBundle`).
    /// @dev On L1 this enforces the pausable check, so withdrawals can be halted; on L2 it is a no-op (the L2
    /// system contract is not pausable). `verifyBundle` is intentionally not guarded: it only records that a
    /// bundle message was included and moves no assets.
    function _ensureNotPaused() internal view virtual {}

    /*//////////////////////////////////////////////////////////////
                            Public entry points
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IInteropHandlerBase
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public {
        _ensureNotPaused();

        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        _validateBundleDestinationContext(bundleHash, interopBundle, _proof.chainId);

        // Execution-address permission gate: permissionless when unset. `msg.sender == address(this)` covers
        // executions initiated through `receiveMessage`, which validates the cross-chain sender itself.
        if (interopBundle.bundleAttributes.executionAddress.length != 0) {
            (uint256 executionChainId, address executionAddress) = InteroperableAddress.parseEvmV1(
                interopBundle.bundleAttributes.executionAddress
            );

            require(
                (msg.sender == address(this) ||
                    ((executionChainId == block.chainid || executionChainId == 0) && executionAddress == msg.sender)),
                ExecutingNotAllowed(
                    bundleHash,
                    InteroperableAddress.formatEvmV1(block.chainid, msg.sender),
                    interopBundle.bundleAttributes.executionAddress
                )
            );
        }

        // Whitelist of executable statuses: any future bundle status is rejected until explicitly allowed.
        require(
            status == BundleStatus.Unreceived || status == BundleStatus.Verified,
            BundleAlreadyProcessed(bundleHash)
        );

        if (status != BundleStatus.Verified) _verifyBundle(_bundle, _proof, bundleHash);

        // Mark the bundle and all its calls executed (CEI) then run the calls; a failing call reverts
        // the whole bundle.
        bundleStatus[bundleHash] = BundleStatus.FullyExecuted;

        uint256 callsLength = interopBundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            callStatus[bundleHash][i] = CallStatus.Executed;
        }

        _executeCalls({
            _sourceChainId: interopBundle.sourceChainId,
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _executeAllCalls: true,
            _providedCallStatus: new CallStatus[](0)
        });

        emit BundleExecuted(bundleHash);
    }

    /// @inheritdoc IInteropHandlerBase
    function verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public {
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        _validateBundleDestinationContext(bundleHash, interopBundle, _proof.chainId);

        require(status == BundleStatus.Unreceived, BundleAlreadyProcessed(bundleHash));

        _verifyBundle(_bundle, _proof, bundleHash);
    }

    /// @inheritdoc IInteropHandlerBase
    function unbundleBundle(bytes memory _bundle, CallStatus[] calldata _providedCallStatus) public {
        _ensureNotPaused();

        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        (uint256 unbundlerChainId, address unbundlerAddress) = InteroperableAddress.parseEvmV1(
            interopBundle.bundleAttributes.unbundlerAddress
        );

        // Unbundler permission gate; `msg.sender == address(this)` covers unbundling initiated through
        // `receiveMessage`, which validates the cross-chain sender itself.
        require(
            msg.sender == address(this) ||
                ((unbundlerChainId == block.chainid || unbundlerChainId == 0) && unbundlerAddress == msg.sender),
            UnbundlingNotAllowed(
                bundleHash,
                InteroperableAddress.formatEvmV1(block.chainid, msg.sender),
                interopBundle.bundleAttributes.unbundlerAddress
            )
        );

        require(
            interopBundle.calls.length == _providedCallStatus.length,
            WrongCallStatusLength(interopBundle.calls.length, _providedCallStatus.length)
        );

        require(status == BundleStatus.Verified || status == BundleStatus.Unbundled, CanNotUnbundle(bundleHash));

        // No destination-context re-validation is needed here: `Verified`/`Unbundled` status is only ever
        // reached through `_validateBundleDestinationContext` (executeBundle/verifyBundle), and every
        // context input is immutable afterwards — the chain ids are committed in the bundle hash and the
        // chain's base-token asset id is set-once (see `L2NativeTokenVault.updateL2`).

        // Mark the bundle Unbundled (CEI) before any external call runs.
        bundleStatus[bundleHash] = BundleStatus.Unbundled;

        uint256 callsLength = interopBundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            CallStatus recordedCallStatus = callStatus[bundleHash][i];
            CallStatus requestedCallStatus = _providedCallStatus[i];
            if (requestedCallStatus == CallStatus.Executed) {
                require(recordedCallStatus == CallStatus.Unprocessed, CallNotExecutable(bundleHash, i));
                callStatus[bundleHash][i] = CallStatus.Executed;
                emit CallProcessed(bundleHash, i, CallStatus.Executed);
            } else if (requestedCallStatus == CallStatus.Cancelled) {
                require(recordedCallStatus != CallStatus.Executed, CallAlreadyExecuted(bundleHash, i));
                if (recordedCallStatus == CallStatus.Unprocessed) {
                    callStatus[bundleHash][i] = CallStatus.Cancelled;
                    emit CallProcessed(bundleHash, i, CallStatus.Cancelled);
                }
            } // Any other requested status leaves the call untouched (skip).
        }

        _executeCalls({
            _sourceChainId: interopBundle.sourceChainId,
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _executeAllCalls: false,
            _providedCallStatus: _providedCallStatus
        });

        emit BundleUnbundled(bundleHash);
    }

    /*//////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Decode an ABI-encoded bundle, compute its hash, and fetch its current status.
    /// @param _bundle ABI-encoded InteropBundle.
    /// @return interopBundle The decoded InteropBundle struct.
    /// @return bundleHash Hash corresponding to the bundle that gets decoded.
    /// @return currentStatus The current BundleStatus of the bundle that gets decoded.
    function _getBundleData(
        bytes memory _bundle
    ) internal view returns (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus currentStatus) {
        // Revert with a clean error on an empty bundle instead of the panic `abi.decode` would produce.
        require(_bundle.length != 0, EmptyBundle());
        interopBundle = abi.decode(_bundle, (InteropBundle));
        require(interopBundle.version == INTEROP_BUNDLE_VERSION, InvalidInteropBundleVersion());
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(interopBundle.sourceChainId, _bundle);
        currentStatus = bundleStatus[bundleHash];
    }

    /// @notice Executes calls in a bundle according to provided or default statuses.
    /// @param _sourceChainId Origin chain ID.
    /// @param _bundleHash Precomputed hash of the bundle.
    /// @param _interopBundle Decoded InteropBundle struct.
    /// @param _executeAllCalls If true, executes all calls; otherwise uses providedCallStatus.
    /// @param _providedCallStatus Desired status array when not executing all calls.
    function _executeCalls(
        uint256 _sourceChainId,
        bytes32 _bundleHash,
        InteropBundle memory _interopBundle,
        bool _executeAllCalls,
        CallStatus[] memory _providedCallStatus
    ) internal {
        uint256 callsLength = _interopBundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            if (!_executeAllCalls) {
                CallStatus requestedCallStatus = _providedCallStatus[i];
                if (requestedCallStatus != CallStatus.Executed) {
                    continue;
                }
            }
            InteropCall memory interopCall = _interopBundle.calls[i];
            require(interopCall.version == INTEROP_CALL_VERSION, InvalidInteropCallVersion());

            _handleCallValue(interopCall.value, _sourceChainId);

            // slither-disable-next-line arbitrary-send-eth
            bytes4 selector = IERC7786Recipient(interopCall.to).receiveMessage{value: interopCall.value}({
                receiveId: keccak256(abi.encodePacked(_bundleHash, i)),
                sender: InteroperableAddress.formatEvmV1(_sourceChainId, interopCall.from),
                payload: interopCall.data
            }); // attributes are not supported yet
            require(selector == IERC7786Recipient.receiveMessage.selector, InvalidSelector(selector));
        }
    }

    /// @notice Proves that the message corresponding to the bundle was included and marks the bundle Verified.
    /// @param _bundle The abi-encoded InteropBundle struct corresponding to the bundle that is to be verified.
    /// @param _proof Proof for the message that corresponds to the bundle that is to be verified.
    /// @param _bundleHash Hash corresponding to the bundle that is to be verified.
    function _verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof, bytes32 _bundleHash) internal {
        // The bundle is authenticated solely by message inclusion plus the sender being the canonical
        // InteropCenter; see {protocol-docs/interop.md} (verification).
        require(
            _proof.message.sender == L2_INTEROP_CENTER_ADDR,
            UnauthorizedMessageSender(L2_INTEROP_CENTER_ADDR, _proof.message.sender)
        );

        // The caller-supplied message data is ignored: substitute the data of the bundle being verified.
        _proof.message.data = bytes.concat(BUNDLE_IDENTIFIER, _bundle);

        require(_proveInclusion(_proof), MessageNotIncluded());

        bundleStatus[_bundleHash] = BundleStatus.Verified;

        emit BundleVerified(_bundleHash);
    }

    /// @notice ERC-7786 recipient entry point, callable only by the handler itself (i.e. only as a call inside
    /// an executing bundle). Rescue mechanism that lets a source-chain sender drive {executeBundle} /
    /// {verifyBundle} / {unbundleBundle} by sending another bundle; see {protocol-docs/interop.md}
    /// (receiveMessage rescue path).
    /// @dev The cross-chain sender's permission is validated here, so the self-called target function skips
    /// its own `msg.sender` check.
    /// @param sender ERC-7930 interoperable address of the message sender.
    /// @param payload `abi.encodeCall` data for one of the three supported functions.
    /// @return selector The function selector of this receiveMessage function, as per ERC-7786.
    function receiveMessage(
        bytes32 /* receiveId */,
        bytes calldata sender,
        bytes calldata payload
    ) external payable override returns (bytes4) {
        require(msg.sender == address(this), Unauthorized(msg.sender));

        // Revert cleanly on a payload too short to carry a selector, instead of the slice-out-of-bounds panic.
        require(payload.length >= 4, PayloadTooShort());
        bytes4 selector = bytes4(payload[:4]);

        (uint256 senderChainId, address senderAddress) = InteroperableAddress.parseEvmV1Calldata(sender);

        // NOTE: legacy payload formats (selectors) must remain supported forever, otherwise messages that
        // were already sent become unexecutable.
        if (selector == this.executeBundle.selector) {
            _handleExecuteBundle(payload, senderChainId, senderAddress, sender);
        } else if (selector == this.verifyBundle.selector) {
            _handleVerifyBundle(payload);
        } else if (selector == this.unbundleBundle.selector) {
            _handleUnbundleBundle(payload, senderChainId, senderAddress, sender);
        } else {
            revert InvalidSelector(selector);
        }

        return IERC7786Recipient.receiveMessage.selector;
    }

    /// @notice Validates the cross-chain sender's execution permission (permissionless when unset), then
    /// self-calls {executeBundle}.
    function _handleExecuteBundle(
        bytes calldata payload,
        uint256 senderChainId,
        address senderAddress,
        bytes calldata sender
    ) internal {
        (bytes memory bundle, MessageInclusionProof memory proof) = abi.decode(
            payload[4:],
            (bytes, MessageInclusionProof)
        );

        (InteropBundle memory interopBundle, bytes32 bundleHash, ) = _getBundleData(bundle);

        if (interopBundle.bundleAttributes.executionAddress.length != 0) {
            (uint256 executionChainId, address executionAddress) = InteroperableAddress.parseEvmV1(
                interopBundle.bundleAttributes.executionAddress
            );

            require(
                (executionChainId == senderChainId || executionChainId == 0) && executionAddress == senderAddress,
                ExecutingNotAllowed(bundleHash, sender, interopBundle.bundleAttributes.executionAddress)
            );
        }

        this.executeBundle(bundle, proof);
    }

    /// @notice Self-calls {verifyBundle}; verification is permissionless, so there is no sender check.
    function _handleVerifyBundle(bytes calldata payload) internal {
        (bytes memory bundle, MessageInclusionProof memory proof) = abi.decode(
            payload[4:],
            (bytes, MessageInclusionProof)
        );

        this.verifyBundle(bundle, proof);
    }

    /// @notice Validates the cross-chain sender's unbundling permission, then self-calls {unbundleBundle}.
    function _handleUnbundleBundle(
        bytes calldata payload,
        uint256 senderChainId,
        address senderAddress,
        bytes calldata sender
    ) internal {
        (bytes memory bundle, CallStatus[] memory providedCallStatus) = abi.decode(payload[4:], (bytes, CallStatus[]));

        (InteropBundle memory interopBundle, bytes32 bundleHash, ) = _getBundleData(bundle);

        (uint256 unbundlerChainId, address unbundlerAddress) = InteroperableAddress.parseEvmV1(
            interopBundle.bundleAttributes.unbundlerAddress
        );

        require(
            (unbundlerChainId == senderChainId || unbundlerChainId == 0) && unbundlerAddress == senderAddress,
            UnbundlingNotAllowed(bundleHash, sender, interopBundle.bundleAttributes.unbundlerAddress)
        );

        this.unbundleBundle(bundle, providedCallStatus);
    }

    /// @notice Validates the bundle's destination context (source/destination chain ids and destination
    /// base-token asset id) against the proof and this chain; see {protocol-docs/interop.md} (verification).
    function _validateBundleDestinationContext(
        bytes32 bundleHash,
        InteropBundle memory interopBundle,
        uint256 proofChainId
    ) internal view {
        require(
            interopBundle.sourceChainId == proofChainId,
            WrongSourceChainId(bundleHash, interopBundle.sourceChainId, proofChainId)
        );

        require(
            interopBundle.destinationChainId == block.chainid,
            WrongDestinationChainId(bundleHash, interopBundle.destinationChainId, block.chainid)
        );

        bytes32 baseTokenAssetId = _expectedDestinationBaseTokenAssetId();
        require(
            interopBundle.destinationBaseTokenAssetId == baseTokenAssetId,
            WrongDestinationBaseTokenAssetId(bundleHash, baseTokenAssetId, interopBundle.destinationBaseTokenAssetId)
        );
    }
}
