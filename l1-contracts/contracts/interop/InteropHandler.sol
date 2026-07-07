// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";

import {
    L2_BASE_TOKEN_HOLDER,
    L2_NATIVE_TOKEN_VAULT,
    L2_MESSAGE_VERIFICATION,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT,
    L2_COMPLEX_UPGRADER_ADDR
} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {IInteropHandler} from "./IInteropHandler.sol";
import {
    BundleStatus,
    CallStatus,
    InteropBundle,
    InteropCall,
    InteropCallExecutedMessage,
    MessageInclusionProof
} from "../common/Messaging.sol";
import {IERC7786Recipient} from "./IERC7786Recipient.sol";
import {InteropHandlerBase} from "./InteropHandlerBase.sol";
import {
    CallAlreadyExecuted,
    CallNotExecutable,
    CanNotUnbundle,
    CannotClaimInteropOnL1Settlement,
    ExecutingNotAllowed,
    UnbundlingNotAllowed,
    WrongCallStatusLength
} from "./InteropErrors.sol";
import {InvalidSelector, Unauthorized} from "../common/L1ContractErrors.sol";
import {IAssetTrackerDataEncoding} from "../bridge/asset-tracker/IAssetTrackerDataEncoding.sol";

/// @title InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract serves as the entry-point for executing, verifying and unbundling interop bundles
/// on L2. The bundle-format machinery lives in `InteropHandlerBase`; this contract provides the
/// L2-specific environment (MessageVerification predeploy, BaseTokenHolder funding, GWAssetTracker
/// notifications, gateway-settlement gating) plus the unbundling and ERC-7786 rescue entry points.
contract InteropHandler is IInteropHandler, IERC7786Recipient, InteropHandlerBase {
    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @inheritdoc IInteropHandler
    function initL2(uint256 _l1ChainId) public reentrancyGuardInitializer onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
    }

    /// @inheritdoc IInteropHandler
    function unbundleBundle(bytes memory _bundle, CallStatus[] calldata _providedCallStatus) public {
        // Interop claiming requires the chain to settle on Gateway so that GWAssetTracker can process
        // the execution confirmation and move balances from pendingInteropBalance to chainBalance.
        // See `_ensureBundleProcessingAllowed` for why this reads `SystemContext` rather than `L2_BRIDGEHUB`.
        _ensureBundleProcessingAllowed();

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
                        Environment-specific hooks
    //////////////////////////////////////////////////////////////*/

    /// @notice Interop claiming requires the chain to settle on Gateway so that GWAssetTracker can process
    /// the execution confirmation and move balances from pendingInteropBalance to chainBalance.
    /// We read the chain's current settlement layer from `SystemContext` (kept in sync with each
    /// batch's bootloader-driven `setSettlementLayerChainId` call); the analogous mapping on the
    /// chain's own `L2Bridgehub` is only written for chains that *settle on this Bridgehub*
    /// (i.e. populated on L1's L1Bridgehub and on a Gateway's L2Bridgehub for the chains it
    /// hosts), and is never written on a chain's own L2Bridgehub for itself.
    function _ensureBundleProcessingAllowed() internal view override {
        require(
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() != L1_CHAIN_ID,
            CannotClaimInteropOnL1Settlement()
        );
    }

    /// @notice Proves message inclusion via the L2 MessageVerification predeploy.
    function _proveMessageInclusion(MessageInclusionProof memory _proof) internal view override returns (bool) {
        return
            L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
                _chainId: _proof.chainId,
                _blockOrBatchNumber: _proof.l1BatchNumber,
                _index: _proof.l2MessageIndex,
                _message: _proof.message,
                _proof: _proof.proof
            });
    }

    /// @notice The base token asset ID of this chain, as registered in the L2 NativeTokenVault.
    function _destinationBaseTokenAssetId() internal view override returns (bytes32) {
        return L2_NATIVE_TOKEN_VAULT.BASE_TOKEN_ASSET_ID();
    }

    /// @notice Transfer base tokens from the BaseTokenHolder instead of minting.
    function _fundCallValue(uint256 _value, uint256 _sourceChainId) internal override {
        L2_BASE_TOKEN_HOLDER.give(address(this), _value, _sourceChainId);
    }

    /// @notice On L2 any bundle shape is allowed.
    function _validateBundle(InteropBundle memory _interopBundle) internal view override {}

    /// @notice On L2 any call target is allowed.
    function _validateCall(InteropCall memory _interopCall) internal view override {}

    /// @notice Sends an L2→L1 message for a single successfully executed interop call.
    /// @dev Called after each executed call so GWAssetTracker can move the call's
    /// balances from pendingInteropBalance to chainBalance during the next settlement.
    /// @param _destinationBaseTokenAssetId Asset ID of the destination chain's base token.
    /// @param _interopCall The interop call that was executed.
    function _afterCallExecuted(
        bytes32 _destinationBaseTokenAssetId,
        InteropCall memory _interopCall
    ) internal override {
        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            abi.encodeCall(
                IAssetTrackerDataEncoding.receiveInteropCallExecuted,
                (
                    InteropCallExecutedMessage({
                        destinationBaseTokenAssetId: _destinationBaseTokenAssetId,
                        interopCall: _interopCall
                    })
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-7786 rescue entry point
    //////////////////////////////////////////////////////////////*/

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

    /// @notice Allows the contract to receive native ETH from L2_BASE_TOKEN_HOLDER.
    /// @dev This is required because L2_BASE_TOKEN_HOLDER.give() transfers ETH to this contract
    ///      before forwarding it to the interop call recipient.
    receive() external payable {
        if (msg.sender != address(L2_BASE_TOKEN_HOLDER)) {
            revert Unauthorized(msg.sender);
        }
    }
}
