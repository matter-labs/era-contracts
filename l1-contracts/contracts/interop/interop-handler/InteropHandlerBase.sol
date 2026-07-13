// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.24;

import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";

import {IInteropHandlerBase} from "./IInteropHandlerBase.sol";
import {
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    BundleStatus,
    CallStatus,
    InteropBundle,
    InteropCall
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
/// @notice Shared, proof-agnostic logic for executing, verifying and unbundling interop bundles. Both the L2
/// system contract (`L2InteropHandler`) and the L1-side `L1InteropHandler` inherit this base.
/// @dev The proof-typed entry points (`executeBundle`/`verifyBundle`) live in the derived contracts, because the
/// two layers authenticate a bundle differently: L2->L2 interop is atomic and proven via the AtomicFlowManager's
/// IMT (`AtomicFinalityProof`), while L2->L1 withdrawals are proven via L1 message inclusion
/// (`MessageInclusionProof`). This base owns only the pieces that do not depend on the proof type: bundle
/// decoding, the bundle/call status state machine, `unbundleBundle`, call execution, and the ERC-7786
/// `receiveMessage` rescue dispatch (whose proof-specific branches route back through virtual hooks).
abstract contract InteropHandlerBase is IInteropHandlerBase, IERC7786Recipient, ReentrancyGuard {
    /// @dev Deprecated. This slot previously held the L1 chain id, which is no longer used (the handler operates
    /// on `block.chainid`). Retained — not removed — to preserve the upgradeable storage layout.
    // slither-disable-next-line uninitialized-state
    uint256 internal __DEPRECATED_L1_CHAIN_ID;

    /// @notice Tracks the processing status of a bundle by its hash.
    mapping(bytes32 bundleHash => BundleStatus bundleStatus) public bundleStatus;

    /// @notice Tracks the individual call statuses within a bundle.
    mapping(bytes32 bundleHash => mapping(uint256 callIndex => CallStatus callStatus)) public callStatus;

    /*//////////////////////////////////////////////////////////////
                        Environment-specific hooks
    //////////////////////////////////////////////////////////////*/

    /// @notice Handles the base-token value that rides along an interop call before it is forwarded.
    /// @dev L2 pulls the value from the `BaseTokenHolder`; L1 forbids non-zero value (withdrawals carry the amount in
    /// their transfer data, not as call value).
    function _handleCallValue(uint256 _value, uint256 _sourceChainId) internal virtual;

    /// @notice The base-token asset ID expected as the bundle's destination base token on this layer.
    function _expectedDestinationBaseTokenAssetId() internal view virtual returns (bytes32);

    /// @notice Guard invoked by the call-executing entry points (`executeBundle` and `unbundleBundle`).
    /// @dev On L1 this enforces the pausable check, so withdrawals can be halted; on L2 it is a no-op (the L2
    /// system contract is not pausable). `verifyBundle` is intentionally not guarded: it only records that a
    /// bundle was proven and moves no assets.
    function _ensureNotPaused() internal view virtual {}

    /// @notice The selector of the derived contract's `executeBundle`, used by `receiveMessage` dispatch.
    /// @dev It differs per layer because the proof type in the signature differs.
    function _executeBundleSelector() internal view virtual returns (bytes4);

    /// @notice The selector of the derived contract's `verifyBundle`, used by `receiveMessage` dispatch.
    function _verifyBundleSelector() internal view virtual returns (bytes4);

    /// @notice Proof-specific `receiveMessage` handler for the `executeBundle` selector. The derived contract
    /// decodes its own proof type, re-checks execution permission for `sender`, and re-enters `executeBundle`.
    function _receiveExecuteBundle(
        bytes calldata _payload,
        uint256 _senderChainId,
        address _senderAddress,
        bytes calldata _sender
    ) internal virtual;

    /// @notice Proof-specific `receiveMessage` handler for the `verifyBundle` selector (permissionless).
    function _receiveVerifyBundle(bytes calldata _payload) internal virtual;

    /*//////////////////////////////////////////////////////////////
                            Public entry points
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IInteropHandlerBase
    function unbundleBundle(bytes memory _bundle, CallStatus[] calldata _providedCallStatus) public {
        _ensureNotPaused();

        // Decode the bundle data, calculate its hash and get the current status of the bundle.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        (uint256 unbundlerChainId, address unbundlerAddress) =
            InteroperableAddress.parseEvmV1(interopBundle.bundleAttributes.unbundlerAddress);

        // Verify that the caller has permission to unbundle the bundle.
        // It's also possible that the caller is InteropHandler itself, in case the unbundling was initiated through receiveMessage.
        require(
            msg.sender == address(this)
                || ((unbundlerChainId == block.chainid || unbundlerChainId == 0) && unbundlerAddress == msg.sender),
            UnbundlingNotAllowed(
                bundleHash,
                InteroperableAddress.formatEvmV1(block.chainid, msg.sender),
                interopBundle.bundleAttributes.unbundlerAddress
            )
        );

        // Verify that the provided call statuses array has the same length as the number of calls in the bundle.
        // That's a measure to protect user from unintended unbundling calls.
        require(
            interopBundle.calls.length == _providedCallStatus.length,
            WrongCallStatusLength(interopBundle.calls.length, _providedCallStatus.length)
        );

        // The bundle status have to be either verified (we know that it's received, but not processed yet), or unbundled.
        // Note, that on the first call to unbundle the status of the bundle should be verified, which validates bundle correctness.
        require(status == BundleStatus.Verified || status == BundleStatus.Unbundled, CanNotUnbundle(bundleHash));

        // Mark the given bundle as unbundled, following CEI pattern.
        bundleStatus[bundleHash] = BundleStatus.Unbundled;

        // We iterate over provided desired statuses of the calls and verify if they are valid (i.e. noncontradictory with current state of the bundle).
        uint256 callsLength = interopBundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            CallStatus recordedCallStatus = callStatus[bundleHash][i];
            CallStatus requestedCallStatus = _providedCallStatus[i];
            if (requestedCallStatus == CallStatus.Executed) {
                // We can only execute unprocessed calls.
                require(recordedCallStatus == CallStatus.Unprocessed, CallNotExecutable(bundleHash, i));
                callStatus[bundleHash][i] = CallStatus.Executed;
                emit CallProcessed(bundleHash, i, CallStatus.Executed);
            } else if (requestedCallStatus == CallStatus.Cancelled) {
                // We can only cancel calls which haven't been executed yet.
                require(recordedCallStatus != CallStatus.Executed, CallAlreadyExecuted(bundleHash, i));
                if (recordedCallStatus == CallStatus.Unprocessed) {
                    // We update the call status if needed.
                    callStatus[bundleHash][i] = CallStatus.Cancelled;
                    emit CallProcessed(bundleHash, i, CallStatus.Cancelled);
                }
            } // If the specified requestedCallStatus is neither Executed or Cancelled, it means we should skip it.
        }

        _executeCalls({
            _sourceChainId: interopBundle.sourceChainId,
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _executeAllCalls: false,
            _providedCallStatus: _providedCallStatus
        });

        // Emit event stating that the bundle was unbundled.
        emit BundleUnbundled(bundleHash);
    }

    /// @notice ERC-7786 recipient entry point, used as a rescue mechanism when the sender is a contract whose
    ///         unbundler/executor is itself: it cannot call `unbundleBundle`/`executeBundle` directly, so it
    ///         sends a bundle whose call targets this handler's `receiveMessage` with the encoded call.
    /// @dev The proof-specific execute/verify branches are delegated to virtual hooks (`_receiveExecuteBundle`
    ///      / `_receiveVerifyBundle`) implemented per layer; the unbundle branch is proof-agnostic and handled
    ///      here. The dispatched selectors are the derived contract's own `executeBundle`/`verifyBundle`
    ///      selectors (which differ per layer by proof type). NOTE: never change these selectors — previously
    ///      sent messages must stay executable.
    /// @param sender ERC-7930 interoperable address of the message sender.
    /// @param payload ABI-encoded function call data with selector and parameters.
    /// @return selector The function selector of this receiveMessage function, as per ERC-7786.
    function receiveMessage(
        bytes32,
        /* receiveId */
        bytes calldata sender,
        bytes calldata payload
    )
        external
        payable
        override
        returns (bytes4)
    {
        // Verify that call to this function is a result of a call being executed, meaning this message came from a valid bundle.
        // This is the only way receiveMessage can be invoked on InteropHandler by itself.
        require(msg.sender == address(this), Unauthorized(msg.sender));

        // Revert cleanly on a payload too short to carry a selector, instead of the slice-out-of-bounds panic.
        require(payload.length >= 4, PayloadTooShort());
        bytes4 selector = bytes4(payload[:4]);

        (uint256 senderChainId, address senderAddress) = InteroperableAddress.parseEvmV1Calldata(sender);

        if (selector == _executeBundleSelector()) {
            _receiveExecuteBundle(payload, senderChainId, senderAddress, sender);
        } else if (selector == _verifyBundleSelector()) {
            _receiveVerifyBundle(payload);
        } else if (selector == this.unbundleBundle.selector) {
            _handleUnbundleBundle(payload, senderChainId, senderAddress, sender);
        } else {
            revert InvalidSelector(selector);
        }

        return IERC7786Recipient.receiveMessage.selector;
    }

    /*//////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Decode an ABI-encoded bundle, compute its hash, and fetch its current status.
    /// @param _bundle ABI-encoded InteropBundle.
    /// @return interopBundle The decoded InteropBundle struct.
    /// @return bundleHash Hash corresponding to the bundle that gets decoded.
    /// @return currentStatus The current BundleStatus of the bundle that gets decoded.
    function _getBundleData(bytes memory _bundle)
        internal
        view
        returns (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus currentStatus)
    {
        // Revert with a clean error on an empty bundle instead of the panic `abi.decode` would produce.
        require(_bundle.length != 0, EmptyBundle());
        interopBundle = abi.decode(_bundle, (InteropBundle));
        require(interopBundle.version == INTEROP_BUNDLE_VERSION, InvalidInteropBundleVersion());
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(interopBundle.sourceChainId, _bundle);
        currentStatus = bundleStatus[bundleHash];
    }

    /// @notice Execution-address permission gate shared by the derived `executeBundle` entry points.
    /// @dev Permissionless when no `executionAddress` is set; otherwise only that address (on this chain, or
    /// chain-agnostic via chainId 0) may execute — or this contract itself, when execution was initiated
    /// through `receiveMessage`.
    function _requireExecutionAllowed(bytes32 _bundleHash, InteropBundle memory _interopBundle) internal view {
        if (_interopBundle.bundleAttributes.executionAddress.length == 0) {
            return;
        }
        (uint256 executionChainId, address executionAddress) =
            InteroperableAddress.parseEvmV1(_interopBundle.bundleAttributes.executionAddress);
        require(
            (msg.sender == address(this)
                    || ((executionChainId == block.chainid || executionChainId == 0)
                        && executionAddress == msg.sender)),
            ExecutingNotAllowed(
                _bundleHash,
                InteroperableAddress.formatEvmV1(block.chainid, msg.sender),
                _interopBundle.bundleAttributes.executionAddress
            )
        );
    }

    /// @notice Requires a bundle to be executable: either never processed, or already proven (`Verified`).
    /// @dev Whitelist approach: any future status is rejected until explicitly allowed.
    function _requireExecutable(bytes32 _bundleHash, BundleStatus _status) internal pure {
        require(
            _status == BundleStatus.Unreceived || _status == BundleStatus.Verified, BundleAlreadyProcessed(_bundleHash)
        );
    }

    /// @notice Shared pre-gate validation for the derived `executeBundle`: pause gate, destination-context
    /// check, caller permission and executability. Both handlers run this identically; the only per-layer
    /// difference is the proof gate that follows (message inclusion on L1, atomic IMT finality on L2) and
    /// the proof-attested source chain id passed here. The handler then calls {_markFullyExecutedAndRun}.
    /// @param _proofSourceChainId Source chain id attested by the proof — the message-inclusion
    /// `proof.chainId` on L1, or the bundle's self-binding `sourceChainId` on the L2 atomic path.
    function _validateExecutable(
        bytes32 _bundleHash,
        InteropBundle memory _interopBundle,
        uint256 _proofSourceChainId,
        BundleStatus _status
    ) internal view {
        _ensureNotPaused();
        _validateBundleDestinationContext(_bundleHash, _interopBundle, _proofSourceChainId);
        _requireExecutionAllowed(_bundleHash, _interopBundle);
        _requireExecutable(_bundleHash, _status);
    }

    /// @notice Shared pre-gate validation for the derived `verifyBundle`: destination-context check plus a
    /// fresh-bundle (`Unreceived`) requirement. The handler then runs its typed proof gate and marks the
    /// bundle `Verified`.
    /// @param _proofSourceChainId See {_validateExecutable}.
    function _validateVerifiable(
        bytes32 _bundleHash,
        InteropBundle memory _interopBundle,
        uint256 _proofSourceChainId,
        BundleStatus _status
    ) internal view {
        _validateBundleDestinationContext(_bundleHash, _interopBundle, _proofSourceChainId);
        require(_status == BundleStatus.Unreceived, BundleAlreadyProcessed(_bundleHash));
    }

    /// @notice Marks a proven bundle `Verified` and emits the event. Shared tail of the derived `verifyBundle`.
    function _markVerified(bytes32 _bundleHash) internal {
        bundleStatus[_bundleHash] = BundleStatus.Verified;
        emit BundleVerified(_bundleHash);
    }

    /// @notice Marks the bundle `FullyExecuted` (CEI) and executes all of its calls — the shared tail of the
    /// derived `executeBundle`. `_executeAllCalls = true`, so any failing call reverts the whole flow, leaving
    /// no state changes.
    function _markFullyExecutedAndRun(bytes32 _bundleHash, InteropBundle memory _interopBundle) internal {
        bundleStatus[_bundleHash] = BundleStatus.FullyExecuted;

        uint256 callsLength = _interopBundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            callStatus[_bundleHash][i] = CallStatus.Executed;
        }

        _executeCalls({
            _sourceChainId: _interopBundle.sourceChainId,
            _bundleHash: _bundleHash,
            _interopBundle: _interopBundle,
            _executeAllCalls: true,
            _providedCallStatus: new CallStatus[](0)
        });

        emit BundleExecuted(_bundleHash);
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
                    // We skip the call.
                    continue;
                }
            }
            InteropCall memory interopCall = _interopBundle.calls[i];
            require(interopCall.version == INTEROP_CALL_VERSION, InvalidInteropCallVersion());

            // Environment-specific handling of the call's base-token value.
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

    /// @notice Validates that a bundle is being executed/verified in the correct destination context.
    /// @param bundleHash Hash of the bundle.
    /// @param interopBundle Decoded bundle.
    /// @param proofChainId The source chain id as attested by the proof (message-inclusion `proof.chainId` on
    /// L1; the bundle's own `sourceChainId` for the self-binding atomic proof on L2).
    function _validateBundleDestinationContext(
        bytes32 bundleHash,
        InteropBundle memory interopBundle,
        uint256 proofChainId
    ) internal view {
        // Verify that the source chainId of the bundle matches the proof's chainId
        require(
            interopBundle.sourceChainId == proofChainId,
            WrongSourceChainId(bundleHash, interopBundle.sourceChainId, proofChainId)
        );

        // Verify that the destination chainId of the bundle is equal to the chainId where it's trying to get executed
        require(
            interopBundle.destinationChainId == block.chainid,
            WrongDestinationChainId(bundleHash, interopBundle.destinationChainId, block.chainid)
        );

        // Verify that the destination base token asset ID of the bundle is equal to the base token asset ID of the chain
        bytes32 baseTokenAssetId = _expectedDestinationBaseTokenAssetId();
        require(
            interopBundle.destinationBaseTokenAssetId == baseTokenAssetId,
            WrongDestinationBaseTokenAssetId(bundleHash, baseTokenAssetId, interopBundle.destinationBaseTokenAssetId)
        );
    }

    /// @notice Shared `receiveMessage` handler for the (proof-agnostic) unbundle branch.
    function _handleUnbundleBundle(
        bytes calldata payload,
        uint256 senderChainId,
        address senderAddress,
        bytes calldata sender
    ) internal {
        (bytes memory bundle, CallStatus[] memory providedCallStatus) = abi.decode(payload[4:], (bytes, CallStatus[]));

        // Decode the bundle to get unbundling permissions
        (InteropBundle memory interopBundle, bytes32 bundleHash,) = _getBundleData(bundle);

        (uint256 unbundlerChainId, address unbundlerAddress) =
            InteroperableAddress.parseEvmV1(interopBundle.bundleAttributes.unbundlerAddress);

        // Verify sender has unbundling permission
        require(
            (unbundlerChainId == senderChainId || unbundlerChainId == 0) && unbundlerAddress == senderAddress,
            UnbundlingNotAllowed(bundleHash, sender, interopBundle.bundleAttributes.unbundlerAddress)
        );

        this.unbundleBundle(bundle, providedCallStatus);
    }
}
