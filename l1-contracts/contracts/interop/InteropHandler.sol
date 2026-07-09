// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";

import {
    L2_BASE_TOKEN_HOLDER,
    L2_NATIVE_TOKEN_VAULT,
    L2_COMPLEX_UPGRADER_ADDR
} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {IL2NativeTokenVault} from "../bridge/ntv/IL2NativeTokenVault.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IAtomicFlowManager} from "../atomic-interop/IAtomicFlowManager.sol";
import {AtomicFinalityProof} from "../atomic-interop/IAtomicInterop.sol";
import {IInteropHandler} from "./IInteropHandler.sol";
import {
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    BundleStatus,
    CallStatus,
    InteropBundle,
    InteropCall
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
    UnbundlingNotAllowed,
    WrongCallStatusLength,
    WrongDestinationChainId,
    WrongDestinationBaseTokenAssetId,
    WrongSourceChainId,
    InvalidInteropBundleVersion,
    InvalidInteropCallVersion
} from "./InteropErrors.sol";
import {InvalidSelector, Unauthorized} from "../common/L1ContractErrors.sol";

/// @title InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract serves as the entry-point for executing, verifying and unbundling interop bundles.
contract InteropHandler is IInteropHandler, IERC7786Recipient, ReentrancyGuard {
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

    /// @notice Returns the native token vault.
    function _nativeTokenVault() internal view returns (IL2NativeTokenVault) {
        return L2_NATIVE_TOKEN_VAULT;
    }

    /// @inheritdoc IInteropHandler
    function initL2(uint256 _l1ChainId) public reentrancyGuardInitializer onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
    }

    /// @inheritdoc IInteropHandler
    function executeBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) public {
        // Interop is atomic. There is no gateway-settlement requirement: an atomic bundle's cross-chain
        // binding comes from the per-leg IMT inclusion proofs authenticated against the interop root,
        // which is built on both L1 and the gateway. Execution is therefore valid regardless of
        // settlement layer, including L1-settled chains.

        // Decode the bundle, compute its hash, read its status.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        // An atomic bundle is never published to L1, so its source chain id is the bundle's own field;
        // the cross-chain binding comes from the IMT inclusion proof (the atomicity gate) below.
        _validateBundleDestinationContext(bundleHash, interopBundle, interopBundle.sourceChainId);
        _requireExecutionAllowed(bundleHash, interopBundle);

        // We can only process bundles that are either unreceived (first time processing) or verified
        // (already verified but not executed). This whitelist approach ensures that if new bundle
        // statuses are added in the future, they will be explicitly rejected until they are explicitly
        // allowed, preventing potential security vulnerabilities.
        require(
            status == BundleStatus.Unreceived || status == BundleStatus.Verified,
            BundleAlreadyProcessed(bundleHash)
        );

        // Atomicity gate: prove every leg of the flow was committed in its source chain's IMT before the
        // deadline, and that this bundle is one of the flow's legs. Reverts otherwise. Skipped if the
        // bundle was already verified via {verifyBundle}. No explicit "block.chainid in flow" check is
        // needed: the bundle self-binds its own destinationChainId (asserted == block.chainid above) and
        // per-send salts make each leg's bundleHash unique to its destination.
        if (status != BundleStatus.Verified) {
            IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).requireFlowFinalized(bundleHash, _finality);
        }

        // No nonReentrant guard. Replay safety is by CEI: _markFullyExecutedAndRun sets bundleStatus =
        // FullyExecuted before running any call, so a reentrant call for THIS bundle hits the status
        // check and reverts; a reentry for a different bundle is independently guarded. A global lock
        // would also block legitimate nested interop.
        _markFullyExecutedAndRun(bundleHash, interopBundle);
    }

    /// @notice Execution-address permission gate shared by executeBundle / verifyBundle.
    /// @dev Permissionless when no `executionAddress` is set; otherwise only that address (on this
    /// chain, or chain-agnostic via chainId 0) may execute — or this contract itself, when execution
    /// was initiated through `receiveMessage`.
    function _requireExecutionAllowed(bytes32 _bundleHash, InteropBundle memory _interopBundle) internal view {
        if (_interopBundle.bundleAttributes.executionAddress.length == 0) {
            return;
        }
        (uint256 executionChainId, address executionAddress) = InteroperableAddress.parseEvmV1(
            _interopBundle.bundleAttributes.executionAddress
        );
        require(
            (msg.sender == address(this) ||
                ((executionChainId == block.chainid || executionChainId == 0) && executionAddress == msg.sender)),
            ExecutingNotAllowed(
                _bundleHash,
                InteroperableAddress.formatEvmV1(block.chainid, msg.sender),
                _interopBundle.bundleAttributes.executionAddress
            )
        );
    }

    /// @notice Marks the bundle `FullyExecuted` (CEI) and executes all of its calls — the shared tail of
    /// executeBundle. `_executeAllCalls = true`, so any failing call reverts the
    /// whole flow, leaving no state changes.
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

    /// @inheritdoc IInteropHandler
    function verifyBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) public {
        // Decode the bundle data, calculate its hash and get the current status of the bundle.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        // An atomic bundle is never published to L1, so its source chain id is the bundle's own field.
        _validateBundleDestinationContext(bundleHash, interopBundle, interopBundle.sourceChainId);

        // If the bundle was already fully executed or unbundled, we revert stating that it was processed already.
        require(status == BundleStatus.Unreceived, BundleAlreadyProcessed(bundleHash));

        // Atomicity gate (view): prove every leg of the flow was committed in its source chain's IMT
        // before the deadline, and that this bundle is one of the flow's legs. Marking the bundle
        // Verified enables the verify->unbundle flow without re-proving.
        IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).requireFlowFinalized(bundleHash, _finality);

        bundleStatus[bundleHash] = BundleStatus.Verified;

        // Emit event stating that the bundle was verified.
        emit BundleVerified(bundleHash);
    }

    /// @inheritdoc IInteropHandler
    function unbundleBundle(bytes memory _bundle, CallStatus[] calldata _providedCallStatus) public {
        // No gateway-settlement requirement: atomic interop is valid on any settlement layer (see
        // {executeBundle}). Unbundling operates on a bundle already marked Verified by {verifyBundle}.

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
    ) external payable override returns (bytes4) {
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
        (bytes memory bundle, AtomicFinalityProof memory finality) = abi.decode(
            payload[4:],
            (bytes, AtomicFinalityProof)
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

        this.executeBundle(bundle, finality);
    }

    function _handleVerifyBundle(bytes calldata payload) internal {
        (bytes memory bundle, AtomicFinalityProof memory finality) = abi.decode(
            payload[4:],
            (bytes, AtomicFinalityProof)
        );

        // Bundle verification is permissionless
        this.verifyBundle(bundle, finality);
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
}
