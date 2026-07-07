// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";

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
} from "../common/Messaging.sol";
import {IERC7786Recipient} from "./IERC7786Recipient.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {InteropDataEncoding} from "./InteropDataEncoding.sol";
import {
    BundleAlreadyProcessed,
    ExecutingNotAllowed,
    MessageNotIncluded,
    UnauthorizedMessageSender,
    WrongDestinationChainId,
    WrongDestinationBaseTokenAssetId,
    WrongSourceChainId,
    InvalidInteropBundleVersion,
    InvalidInteropCallVersion
} from "./InteropErrors.sol";
import {InvalidSelector} from "../common/L1ContractErrors.sol";
import {L2_INTEROP_CENTER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @title InteropHandlerBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The environment-independent core of interop bundle processing: decoding, hashing, destination
/// validation, inclusion verification and call execution. This is the single place that understands the
/// interop bundle wire format; environment specifics (how inclusion is proven, how call value is funded,
/// which chains may claim, post-execution accounting) are provided by the L2 `InteropHandler` predeploy
/// and the `L1InteropHandler` via the virtual hooks at the bottom.
abstract contract InteropHandlerBase is IInteropHandlerBase, ReentrancyGuard {
    /// @notice The chain ID of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public L1_CHAIN_ID;

    /// @notice Tracks the processing status of a bundle by its hash.
    mapping(bytes32 bundleHash => BundleStatus bundleStatus) public bundleStatus;

    /// @notice Tracks the individual call statuses within a bundle.
    mapping(bytes32 bundleHash => mapping(uint256 callIndex => CallStatus callStatus)) public callStatus;

    /// @inheritdoc IInteropHandlerBase
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public virtual {
        // Environment-specific gate: on L2 this requires the chain to settle on a Gateway (so that
        // GWAssetTracker can process execution confirmations); on L1 it restricts the caller.
        _ensureBundleProcessingAllowed();

        // Decode the bundle data, calculate its hash and get the current status of the bundle.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        _validateBundleDestinationContext(bundleHash, interopBundle, _proof.chainId);
        // Environment-specific bundle-level policy (e.g. L1 requires a single-call bundle).
        _validateBundle(interopBundle);

        // If the execution address is not specified then the execution is permissionless.
        if (interopBundle.bundleAttributes.executionAddress.length != 0) {
            (uint256 executionChainId, address executionAddress) = InteroperableAddress.parseEvmV1(
                interopBundle.bundleAttributes.executionAddress
            );

            // Verify that the caller has permission to execute the bundle.
            // Note, that in case the executionAddress wasn't specified in the bundle then executing is permissionless, as documented in Messaging.sol
            // It's also possible that the caller is InteropHandler itself, in case the execution was initiated through receiveMessage.
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

        // We can only process bundles that are either unreceived (first time processing) or verified (already verified but not executed).
        // This whitelist approach ensures that if new bundle statuses are added in the future, they will be explicitly rejected
        // until they are explicitly allowed, preventing potential security vulnerabilities.
        require(
            status == BundleStatus.Unreceived || status == BundleStatus.Verified,
            BundleAlreadyProcessed(bundleHash)
        );

        // Verify the bundle inclusion, if not done yet.
        if (status != BundleStatus.Verified) _verifyBundle(_bundle, _proof, bundleHash);

        // Mark the given bundle as fully executed, following CEI pattern.
        bundleStatus[bundleHash] = BundleStatus.FullyExecuted;

        // Update callStatus of the calls which are to be executed.
        uint256 callsLength = interopBundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            callStatus[bundleHash][i] = CallStatus.Executed;
        }

        // Execute all of the calls.
        // Since we provide the flag `_executeAllCalls` to be true, if either of the calls fail,
        // the `_executeCalls` will fail as well, thus making the whole flow revert, no changes will be applied to the state.
        _executeCalls({
            _sourceChainId: interopBundle.sourceChainId,
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _executeAllCalls: true,
            _providedCallStatus: new CallStatus[](0)
        });

        // Emit event stating that the bundle was executed.
        emit BundleExecuted(bundleHash);
    }

    /// @inheritdoc IInteropHandlerBase
    function verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public virtual {
        // Decode the bundle data, calculate its hash and get the current status of the bundle.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        _validateBundleDestinationContext(bundleHash, interopBundle, _proof.chainId);

        // If the bundle was already fully executed or unbundled, we revert stating that it was processed already.
        require(status == BundleStatus.Unreceived, BundleAlreadyProcessed(bundleHash));

        // Verify the bundle inclusion
        _verifyBundle(_bundle, _proof, bundleHash);
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
                    // We skip the call.
                    continue;
                }
            }
            InteropCall memory interopCall = _interopBundle.calls[i];
            require(interopCall.version == INTEROP_CALL_VERSION, InvalidInteropCallVersion());

            // Environment-specific per-call policy (e.g. L1 restricts the allowed call targets).
            _validateCall(interopCall);

            if (interopCall.value > 0) {
                // Environment-specific funding of the call value (L2: BaseTokenHolder; L1: unsupported).
                _fundCallValue(interopCall.value, _sourceChainId);
            }
            // slither-disable-next-line arbitrary-send-eth
            bytes4 selector = IERC7786Recipient(interopCall.to).receiveMessage{value: interopCall.value}({
                receiveId: keccak256(abi.encodePacked(_bundleHash, i)),
                sender: InteroperableAddress.formatEvmV1(_sourceChainId, interopCall.from),
                payload: interopCall.data
            }); // attributes are not supported yet
            require(selector == IERC7786Recipient.receiveMessage.selector, InvalidSelector(selector));

            // Environment-specific post-execution accounting (L2: notify GWAssetTracker; L1: none).
            _afterCallExecuted(_interopBundle.destinationBaseTokenAssetId, interopCall);
        }
    }

    /// @notice Verifies the bundle, meaning checking that the message corresponding to the bundle was received.
    /// @param _bundle The abi-encoded InteropBundle struct corresponding to the bundle that is to be verified.
    /// @param _proof Proof for the message that corresponds to the bundle that is to be verified.
    /// @param _bundleHash Hash corresponding to the bundle that is to be verified.
    /// That message gets sent to L1 by origin chain in InteropCenter contract, and is picked up and included in receiving chain by sequencer.
    function _verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof, bytes32 _bundleHash) internal {
        // Verify that the message came from the legitimate InteropCenter.
        // It is expected that all allowed messages have gone through the GWAssetTracker which
        // ensured that if the `L2_INTEROP_CENTER_ADDR` is the sender of the message, then the message
        // corresponds to a bundle with the valid balance changes.
        require(
            _proof.message.sender == L2_INTEROP_CENTER_ADDR,
            UnauthorizedMessageSender(L2_INTEROP_CENTER_ADDR, _proof.message.sender)
        );

        // Substitute provided message data with data corresponding to the bundle currently being verified.
        _proof.message.data = bytes.concat(BUNDLE_IDENTIFIER, _bundle);

        // Environment-specific inclusion proof (L2: MessageVerification predeploy; L1: MessageRoot).
        bool isIncluded = _proveMessageInclusion(_proof);

        require(isIncluded, MessageNotIncluded());

        bundleStatus[_bundleHash] = BundleStatus.Verified;

        // Emit event stating that the bundle was verified.
        emit BundleVerified(_bundleHash);
    }

    /// @notice Validates that the bundle is being processed on the chain and context it was destined for.
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
        bytes32 baseTokenAssetId = _destinationBaseTokenAssetId();
        require(
            interopBundle.destinationBaseTokenAssetId == baseTokenAssetId,
            WrongDestinationBaseTokenAssetId(bundleHash, baseTokenAssetId, interopBundle.destinationBaseTokenAssetId)
        );
    }

    /*//////////////////////////////////////////////////////////////
                        Environment-specific hooks
    //////////////////////////////////////////////////////////////*/

    /// @notice Gate for bundle processing (execute/unbundle) in the concrete environment.
    function _ensureBundleProcessingAllowed() internal view virtual;

    /// @notice Proves the inclusion of the message corresponding to a bundle.
    function _proveMessageInclusion(MessageInclusionProof memory _proof) internal view virtual returns (bool);

    /// @notice The base token asset ID that bundles destined for this chain must carry.
    function _destinationBaseTokenAssetId() internal view virtual returns (bytes32);

    /// @notice Makes `_value` of base token available to this contract for the call being executed.
    function _fundCallValue(uint256 _value, uint256 _sourceChainId) internal virtual;

    /// @notice Environment-specific bundle-level policy check before execution.
    function _validateBundle(InteropBundle memory _interopBundle) internal view virtual;

    /// @notice Environment-specific per-call policy check before execution.
    function _validateCall(InteropCall memory _interopCall) internal view virtual;

    /// @notice Environment-specific accounting after a call was successfully executed.
    function _afterCallExecuted(bytes32 _destinationBaseTokenAssetId, InteropCall memory _interopCall) internal virtual;
}
