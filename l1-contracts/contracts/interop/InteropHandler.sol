// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_MESSAGE_VERIFICATION, L2_INTEROP_CENTER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IInteropHandler} from "./IInteropHandler.sol";
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, MessageInclusionProof, CallStatus, BundleStatus} from "../common/Messaging.sol";
import {IERC7786Recipient} from "./IERC7786Recipient.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {InteropDataEncoding} from "./InteropDataEncoding.sol";
import {InteroperableAddress} from "@openzeppelin/contracts-master/utils/draft-InteroperableAddress.sol";
import {MessageNotIncluded, BundleAlreadyProcessed, CanNotUnbundle, CallAlreadyExecuted, CallNotExecutable, WrongCallStatusLength, UnbundlingNotAllowed, ExecutingNotAllowed, BundleVerifiedAlready, UnauthorizedMessageSender, WrongDestinationChainId} from "./InteropErrors.sol";
import {InvalidSelector} from "../common/L1ContractErrors.sol";

/// @title InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract serves as the entry-point for executing, verifying and unbundling interop bundles.
contract InteropHandler is IInteropHandler, ReentrancyGuard {
    /// @notice Tracks the processing status of a bundle by its hash.
    mapping(bytes32 bundleHash => BundleStatus bundleStatus) public bundleStatus;

    /// @notice Tracks the individual call statuses within a bundle.
    mapping(bytes32 bundleHash => mapping(uint256 callIndex => CallStatus callStatus)) public callStatus;

    /// KL todo remove constructors for ZK OS forward compatibility.
    constructor() reentrancyGuardInitializer {}

    /// @notice Executes a full bundle atomically.
    /// @dev Reverts if any call fails, or if bundle has been processed already.
    /// @param _bundle ABI-encoded InteropBundle to execute.
    /// @param _proof Inclusion proof for the bundle message. The bundle message itself gets broadcasted by InteropCenter contract whenever a bundle is sent.
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public nonReentrant {
        // Decode the bundle data, calculate its hash and get the current status of the bundle.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(
            _bundle,
            _proof.chainId
        );

        // Verify that the destination chainId of the bundle is equal to the chainId where it's trying to get executed
        require(
            interopBundle.destinationChainId == block.chainid,
            WrongDestinationChainId(bundleHash, interopBundle.destinationChainId, block.chainid)
        );

        (uint256 executionChainId, address executionAddress) = InteroperableAddress.parseEvmV1(interopBundle.bundleAttributes.executionAddress);

        // Verify that the caller has permission to execute the bundle.
        // Note, that in case the executionAddress wasn't specified in the bundle then executing is permissionless, as documented in Messaging.sol
        // It's also possible that the caller is InteropHandler itself, in case the execution was initiated through receiveMessage.
        require(
            (interopBundle.bundleAttributes.executionAddress.length == 0 || msg.sender == address(this) ||
                (block.chainid == executionChainId && msg.sender == executionAddress)),
            ExecutingNotAllowed(bundleHash, InteroperableAddress.formatEvmV1(block.chainid, msg.sender), interopBundle.bundleAttributes.executionAddress)
        );

        // We shouldn't process bundles which are either fully executed, or were unbundled here.
        // If the bundle if fully executed, it's not expected that anything else should be done with the bundle, it's finalized already.
        // If the bundle were unbundled, it's either fully finalized (all calls are cancelled or executed), in which case nothing else could be done, similar to above,
        // or some of the calls are still unprocessed, in this case they should be processed via unbundling.
        require(
            status != BundleStatus.FullyExecuted && status != BundleStatus.Unbundled,
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
            _sourceChainId: _proof.chainId,
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _executeAllCalls: true,
            _providedCallStatus: new CallStatus[](0)
        });

        // Emit event stating that the bundle was executed.
        emit BundleExecuted(bundleHash);
    }

    /// @notice Verifies receipt of a bundle without executing calls.
    /// @dev Marks bundle as Verified on success.
    /// @param _bundle ABI-encoded InteropBundle to verify.
    /// @param _proof Inclusion proof for the bundle message. The bundle message itself gets broadcasted by InteropCenter contract whenever a bundle is sent.
    function verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public nonReentrant {
        // Decode the bundle data, calculate its hash and get the current status of the bundle.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(
            _bundle,
            _proof.chainId
        );

        // Verify that the destination chainId of the bundle is equal to the chainId where it's trying to get verified
        require(
            interopBundle.destinationChainId == block.chainid,
            WrongDestinationChainId(bundleHash, interopBundle.destinationChainId, block.chainid)
        );

        // If the bundle was already fully executed or unbundled, we revert stating that it was processed already.
        require(
            status == BundleStatus.Unreceived || status == BundleStatus.Verified,
            BundleAlreadyProcessed(bundleHash)
        );

        // Revert if the bundle was verified already.
        require(status != BundleStatus.Verified, BundleVerifiedAlready(bundleHash));

        // Verify the bundle inclusion
        _verifyBundle(_bundle, _proof, bundleHash);
    }

    /// @notice Function used to unbundle the bundle. It's present to give more flexibility in cancelling and overall processing of bundles.
    ///         Can be invoked multiple times until all calls are processed.
    /// @param _sourceChainId Originating chain ID of the bundle.
    /// @param _bundle ABI-encoded InteropBundle to unbundle.
    /// @param _providedCallStatus Array of desired statuses per call.
    function unbundleBundle(
        uint256 _sourceChainId,
        bytes memory _bundle,
        CallStatus[] calldata _providedCallStatus
    ) public nonReentrant {
        // Decode the bundle data, calculate its hash and get the current status of the bundle.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(
            _bundle,
            _sourceChainId
        );

        // Verify that the destination chainId of the bundle is equal to the chainId where it's trying to get unbundled
        require(
            interopBundle.destinationChainId == block.chainid,
            WrongDestinationChainId(bundleHash, interopBundle.destinationChainId, block.chainid)
        );

        (uint256 unbundlerChainId, address unbundlerAddress) = InteroperableAddress.parseEvmV1(interopBundle.bundleAttributes.unbundlerAddress);

        // Verify that the caller has permission to unbundle the bundle.
        // It's also possible that the caller is InteropHandler itself, in case the unbundling was initiated through receiveMessage.
        require(
            msg.sender == address(this) || (unbundlerChainId == block.chainid && unbundlerAddress == msg.sender),
            UnbundlingNotAllowed(bundleHash, InteroperableAddress.formatEvmV1(block.chainid, msg.sender), interopBundle.bundleAttributes.unbundlerAddress)
        );

        // Verify that the provided call statuses array has the same length as the number of calls in the bundle.
        // That's a measure to protect user from unintended unbundling calls.
        require(
            interopBundle.calls.length == _providedCallStatus.length,
            WrongCallStatusLength(interopBundle.calls.length, _providedCallStatus.length)
        );

        // The bundle status have to be either verified (we know that it's received, but not processed yet), or unbundled.
        // Note, that on the first call to unbundle the status of the bundle should be verified.
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
            _sourceChainId: _sourceChainId,
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _executeAllCalls: false,
            _providedCallStatus: _providedCallStatus
        });

        // Emit event stating that the bundle was unbundled.
        emit BundleUnbundled(bundleHash);
    }

    /*//////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Decode an ABI-encoded bundle, compute its hash, and fetch its current status.
    /// @param _bundle ABI-encoded InteropBundle.
    /// @param _sourceChainId Origin chain ID.
    /// @return interopBundle The decoded InteropBundle struct.
    /// @return bundleHash Hash corresponding to the bundle that gets decoded.
    /// @return currentStatus The current BundleStatus of the bundle that gets decoded.
    function _getBundleData(
        bytes memory _bundle,
        uint256 _sourceChainId
    ) internal view returns (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus currentStatus) {
        interopBundle = abi.decode(_bundle, (InteropBundle));
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(_sourceChainId, _bundle);
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

            L2_BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), interopCall.value);
            // slither-disable-next-line arbitrary-send-eth
            bytes4 selector = IERC7786Recipient(interopCall.to).receiveMessage{value: interopCall.value}({
                receiveId: keccak256(abi.encodePacked(_bundleHash, i)),
                sender: InteroperableAddress.formatEvmV1(_sourceChainId, interopCall.from),
                payload: interopCall.data
            }); // attributes are not supported yet
            require(selector == IERC7786Recipient.receiveMessage.selector, InvalidSelector(selector));
        }
    }

    /// @notice Verifies the bundle, meaning checking that the message corresponding to the bundle was received.
    /// @param _bundle The abi-encoded InteropBundle struct corresponding to the bundle that is to be verified.
    /// @param _proof Proof for the message that corresponds to the bundle that is to be verified.
    /// @param _bundleHash Hash corresponding to the bundle that is to be verified.
    /// That message gets sent to L1 by origin chain in InteropCenter contract, and is picked up and included in receiving chain by sequencer.
    function _verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof, bytes32 _bundleHash) internal {
        // Verify that the message came from the legitimate InteropCenter
        require(
            _proof.message.sender == L2_INTEROP_CENTER_ADDR,
            UnauthorizedMessageSender(L2_INTEROP_CENTER_ADDR, _proof.message.sender)
        );

        // Substitute provided message data with data corresponding to the bundle currently being verified.
        _proof.message.data = bytes.concat(BUNDLE_IDENTIFIER, _bundle);

        bool isIncluded = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
            _chainId: _proof.chainId,
            _blockOrBatchNumber: _proof.l1BatchNumber,
            _index: _proof.l2MessageIndex,
            _message: _proof.message,
            _proof: _proof.proof
        });

        require(isIncluded, MessageNotIncluded());

        bundleStatus[_bundleHash] = BundleStatus.Verified;

        // Emit event stating that the bundle was verified.
        emit BundleVerified(_bundleHash);
    }
}
