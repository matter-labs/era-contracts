// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";

import {
    L2_BASE_TOKEN_HOLDER,
    L2_INTEROP_CENTER_ADDR,
    L2_NATIVE_TOKEN_VAULT,
    L2_MESSAGE_VERIFICATION,
    L2_COMPLEX_UPGRADER_ADDR
} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {IL2NativeTokenVault} from "../bridge/ntv/IL2NativeTokenVault.sol";
import {IInteropHandler} from "./IInteropHandler.sol";
import {ShadowAccount, ShadowAccountCall, ShadowAccountCallType} from "./ShadowAccount.sol";
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
    CallAlreadyExecuted,
    CallNotExecutable,
    CanNotUnbundle,
    ExecutingNotAllowed,
    MessageNotIncluded,
    UnauthorizedMessageSender,
    UnbundlingNotAllowed,
    WrongCallStatusLength,
    WrongDestinationChainId,
    WrongDestinationBaseTokenAssetId,
    WrongSourceChainId,
    InvalidInteropBundleVersion,
    InvalidInteropCallVersion,
    ShadowAccountDeploymentFailed
} from "./InteropErrors.sol";
import {InvalidSelector, Unauthorized} from "../common/L1ContractErrors.sol";

/// @title InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract serves as the entry-point for executing, verifying and unbundling interop bundles.
contract InteropHandler is IInteropHandler, ReentrancyGuard {
    /// @notice The chain ID of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public L1_CHAIN_ID;

    /// @notice Tracks the processing status of a bundle by its hash.
    mapping(bytes32 bundleHash => BundleStatus bundleStatus) public bundleStatus;

    /// @notice Tracks the individual call statuses within a bundle.
    mapping(bytes32 bundleHash => mapping(uint256 callIndex => CallStatus callStatus)) public callStatus;

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Returns the interop center address. Virtual to allow override in private interop.
    function _interopCenterAddr() internal view virtual returns (address) {
        return L2_INTEROP_CENTER_ADDR;
    }

    /// @notice Returns the native token vault. Virtual to allow override in private interop.
    function _nativeTokenVault() internal view virtual returns (IL2NativeTokenVault) {
        return L2_NATIVE_TOKEN_VAULT;
    }

    /// @inheritdoc IInteropHandler
    function initL2(uint256 _l1ChainId) public reentrancyGuardInitializer onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
    }

    /// @inheritdoc IInteropHandler
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public {
        // Decode the bundle data, calculate its hash and get the current status of the bundle.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        _validateBundleDestinationContext(bundleHash, interopBundle, _proof.chainId);

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

    /// @inheritdoc IInteropHandler
    function verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public {
        // Decode the bundle data, calculate its hash and get the current status of the bundle.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        _validateBundleDestinationContext(bundleHash, interopBundle, _proof.chainId);

        // If the bundle was already fully executed or unbundled, we revert stating that it was processed already.
        require(status == BundleStatus.Unreceived, BundleAlreadyProcessed(bundleHash));

        // Verify the bundle inclusion
        _verifyBundle(_bundle, _proof, bundleHash);
    }

    /// @inheritdoc IInteropHandler
    function unbundleBundle(bytes memory _bundle, CallStatus[] calldata _providedCallStatus) public {
        // Decode the bundle data, calculate its hash and get the current status of the bundle.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        (uint256 unbundlerChainId, address unbundlerAddress) = InteroperableAddress.parseEvmV1(
            interopBundle.bundleAttributes.unbundlerAddress
        );

        // Verify that the caller has permission to unbundle the bundle.
        // It's also possible that the caller is InteropHandler itself, in case the unbundling was initiated through receiveMessage.
        require(
            msg.sender == address(this) ||
                ((unbundlerChainId == block.chainid || unbundlerChainId == 0) && unbundlerAddress == msg.sender),
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

            if (interopCall.value > 0) {
                // Transfer base tokens from the BaseTokenHolder instead of minting.
                L2_BASE_TOKEN_HOLDER.give(address(this), interopCall.value, _sourceChainId);
            }

            if (interopCall.shadowAccount) {
                // Execute via shadow account - deploy if needed and call the target
                _executeViaShadowAccount({
                    _ownerChainId: _sourceChainId,
                    _ownerAddress: interopCall.from,
                    _to: interopCall.to,
                    _value: interopCall.value,
                    _data: interopCall.data
                });
            } else {
                // Normal execution via receiveMessage
                // slither-disable-next-line arbitrary-send-eth
                bytes4 selector = IERC7786Recipient(interopCall.to).receiveMessage{value: interopCall.value}({
                    receiveId: keccak256(abi.encodePacked(_bundleHash, i)),
                    sender: InteroperableAddress.formatEvmV1(_sourceChainId, interopCall.from),
                    payload: interopCall.data
                }); // attributes are not supported yet
                require(selector == IERC7786Recipient.receiveMessage.selector, InvalidSelector(selector));
            }
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
        address interopCenter = _interopCenterAddr();
        require(
            _proof.message.sender == interopCenter,
            UnauthorizedMessageSender(interopCenter, _proof.message.sender)
        );

        // Substitute provided message data with format-specific data.
        _proof.message.data = _getBundleMessageData(_bundle);

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

    /// @notice Returns the message data for bundle verification. Override for private interop format.
    function _getBundleMessageData(bytes memory _bundle) internal view virtual returns (bytes memory) {
        return bytes.concat(BUNDLE_IDENTIFIER, _bundle);
    }

    /// @notice The sole purpose of this function is to serve as a rescue mechanism in case the sender is a contract,
    ///         the unbundler chainid is set to the sender chainid and the unbundler address is set to the contract's address.
    ///         In particular, this happens when the unbundler is not specified.
    ///         In such a case, the contract might nol be able to call `InteropHandler.unbundleBundle` directly.
    ///         Instead, it's able to send another bundle which calls `InteropHandler.unbundleBundle` via the `receiveMessage` function.
    /// @dev Implements ERC-7786 recipient interface. The payload must be encoded using abi.encodeCall
    ///      with one of the following function selectors:
    ///      - executeBundle: payload = abi.encodeCall(InteropHandler.executeBundle, (bundle, proof))
    ///      - unbundleBundle: payload = abi.encodeCall(InteropHandler.unbundleBundle, (bundle, providedCallStatus))
    ///      The sender must have appropriate permissions (executionAddress or unbundlerAddress) which are
    ///      validated before calling the respective internal functions. Since this function validates
    ///      permissions, the called functions (executeBundle/unbundleBundle) will bypass their own
    ///      permission checks when called from this contract (msg.sender == address(this)).
    /// @param sender ERC-7930 interoperable address of the message sender.
    /// @param payload ABI-encoded function call data with selector and parameters.
    /// @return selector The function selector of this receiveMessage function, as per ERC-7786.
    function receiveMessage(
        bytes32 /* receiveId */,
        bytes calldata sender,
        bytes calldata payload
    ) external payable returns (bytes4) {
        // Verify that call to this function is a result of a call being executed, meaning this message came from a valid bundle.
        // This is the only way receiveMessage can be invoked on InteropHandler by itself.
        require(msg.sender == address(this), Unauthorized(msg.sender));

        bytes4 selector = bytes4(payload[:4]);

        (uint256 senderChainId, address senderAddress) = InteroperableAddress.parseEvmV1Calldata(sender);

        // NOTE: it is important that we always support the legacy messages formats (i.e. dont change selectors)
        // since otherwise the messages that were sent before won't be executable.
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

        // Decode the bundle to get execution permissions
        (InteropBundle memory interopBundle, , ) = _getBundleData(bundle);

        // If the execution address is not specified then the execution is permissionless.
        if (interopBundle.bundleAttributes.executionAddress.length != 0) {
            (uint256 executionChainId, address executionAddress) = InteroperableAddress.parseEvmV1(
                interopBundle.bundleAttributes.executionAddress
            );

            // Verify sender has execution permission
            require(
                (executionChainId == senderChainId || executionChainId == 0) && executionAddress == senderAddress,
                ExecutingNotAllowed(keccak256(bundle), sender, interopBundle.bundleAttributes.executionAddress)
            );
        }

        this.executeBundle(bundle, proof);
    }

    function _handleVerifyBundle(bytes calldata payload) internal {
        (bytes memory bundle, MessageInclusionProof memory proof) = abi.decode(
            payload[4:],
            (bytes, MessageInclusionProof)
        );

        // Bundle verification is permissionless
        this.verifyBundle(bundle, proof);
    }

    function _handleUnbundleBundle(
        bytes calldata payload,
        uint256 senderChainId,
        address senderAddress,
        bytes calldata sender
    ) internal {
        (bytes memory bundle, CallStatus[] memory providedCallStatus) = abi.decode(payload[4:], (bytes, CallStatus[]));

        // Decode the bundle to get unbundling permissions
        (InteropBundle memory interopBundle, , ) = _getBundleData(bundle);

        (uint256 unbundlerChainId, address unbundlerAddress) = InteroperableAddress.parseEvmV1(
            interopBundle.bundleAttributes.unbundlerAddress
        );

        // Verify sender has unbundling permission
        require(
            (unbundlerChainId == senderChainId || unbundlerChainId == 0) && unbundlerAddress == senderAddress,
            UnbundlingNotAllowed(keccak256(bundle), sender, interopBundle.bundleAttributes.unbundlerAddress)
        );

        this.unbundleBundle(bundle, providedCallStatus);
    }

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
        bytes32 baseTokenAssetId = _nativeTokenVault().BASE_TOKEN_ASSET_ID();
        require(
            interopBundle.destinationBaseTokenAssetId == baseTokenAssetId,
            WrongDestinationBaseTokenAssetId(bundleHash, baseTokenAssetId, interopBundle.destinationBaseTokenAssetId)
        );
    }

    /// @notice Allows the contract to receive native ETH from L2_BASE_TOKEN_HOLDER.
    /// @dev This is required because L2_BASE_TOKEN_HOLDER.give() transfers ETH to this contract
    ///      before forwarding it to the interop call recipient.
    receive() external payable {
        if (msg.sender != address(L2_BASE_TOKEN_HOLDER)) {
            revert Unauthorized(msg.sender);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        Shadow Account Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a call via the sender's shadow account on this chain.
    /// @dev Deploys the shadow account if it doesn't exist yet. Wraps the original InteropCall's
    /// `to`, `value`, and `data` into a ShadowAccountCall[] payload and delivers it via
    /// receiveMessage — so the sender just sets `shadowAccount: true` and specifies the target
    /// in the normal `to` field, without having to encode anything special in `data`.
    function _executeViaShadowAccount(
        uint256 _ownerChainId,
        address _ownerAddress,
        address _to,
        uint256 _value,
        bytes memory _data
    ) internal {
        address shadowAccountAddr = _getOrDeployShadowAccount(_ownerChainId, _ownerAddress);
        bytes memory senderAddress = InteroperableAddress.formatEvmV1(_ownerChainId, _ownerAddress);

        // Wrap the original call into a single-element ShadowAccountCall[]
        ShadowAccountCall[] memory calls = new ShadowAccountCall[](1);
        calls[0] = ShadowAccountCall({
            callType: ShadowAccountCallType.Call,
            target: _to,
            value: _value,
            data: _data
        });

        // slither-disable-next-line arbitrary-send-eth
        bytes4 selector = IERC7786Recipient(shadowAccountAddr).receiveMessage{value: _value}({
            receiveId: bytes32(0),
            sender: senderAddress,
            payload: abi.encode(calls)
        });
        require(selector == IERC7786Recipient.receiveMessage.selector, InvalidSelector(selector));
    }

    /// @notice Gets or deploys a shadow account for the given owner.
    function _getOrDeployShadowAccount(
        uint256 _ownerChainId,
        address _ownerAddress
    ) internal returns (address shadowAccountAddr) {
        shadowAccountAddr = _computeShadowAccountAddress(_ownerChainId, _ownerAddress);

        if (shadowAccountAddr.code.length > 0) {
            return shadowAccountAddr;
        }

        bytes memory fullOwnerAddress = InteroperableAddress.formatEvmV1(_ownerChainId, _ownerAddress);
        ShadowAccount account = new ShadowAccount{salt: bytes32(0)}(fullOwnerAddress);

        require(address(account) != address(0), ShadowAccountDeploymentFailed());

        emit ShadowAccountDeployed(address(account), _ownerChainId, _ownerAddress);
    }

    /// @notice Computes the deterministic address of a shadow account for a given owner.
    /// @param _ownerChainId The chain ID of the owner.
    /// @param _ownerAddress The EVM address of the owner on the source chain.
    /// @return The address where the shadow account is/will be deployed.
    function getShadowAccountAddress(uint256 _ownerChainId, address _ownerAddress) external view returns (address) {
        return _computeShadowAccountAddress(_ownerChainId, _ownerAddress);
    }

    /// @notice Internal function to compute the expected shadow account address.
    function _computeShadowAccountAddress(
        uint256 _ownerChainId,
        address _ownerAddress
    ) internal view returns (address) {
        bytes memory fullOwnerAddress = InteroperableAddress.formatEvmV1(_ownerChainId, _ownerAddress);
        bytes memory bytecode = abi.encodePacked(type(ShadowAccount).creationCode, abi.encode(fullOwnerAddress));
        bytes32 bytecodeHash = keccak256(bytecode);

        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0x0), bytecodeHash))))
            );
    }
}
