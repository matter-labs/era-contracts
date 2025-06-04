// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_MESSAGE_VERIFICATION} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IInteropHandler, CallStatus, BundleStatus} from "./IInteropHandler.sol";
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, MessageInclusionProof} from "../common/Messaging.sol";
import {IERC7786Receiver} from "./IERC7786Receiver.sol";
error MessageNotIncluded();
error BundleAlreadyProcessed(bytes32 bundleHash);
error CanNotUnbundle(bytes32 bundleHash);
error InvalidSelector(bytes4 selector);
error CallNotExecutable(bytes32 bundleHash, uint256 callIndex);

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that handles the interop bundles.
 */
contract InteropHandler is IInteropHandler {
    /// @notice The balances of the users.
    mapping(bytes32 bundleHash => BundleStatus bundleStatus) public bundleStatus;

    /// @notice The status of the calls in the bundle. The status of the bundle must be Unbundled.
    mapping(bytes32 bundleHash => mapping(uint256 callIndex => CallStatus callStatus)) public callStatus;

    /// @notice Executes the bundle is the normal case
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public {
        _verifyBundle(_bundle, _proof);
        InteropBundle memory interopBundle = abi.decode(_bundle, (InteropBundle));
        bytes32 bundleHash = _calculateBundleHash(
            _proof.chainId,
            interopBundle.sendingBlockNumber,
            _proof.l2MessageIndex,
            _bundle
        );

        BundleStatus status = bundleStatus[bundleHash];
        if (status == BundleStatus.FullyExecuted || status == BundleStatus.Unbundled) {
            revert BundleAlreadyProcessed(bundleHash);
        }
        bundleStatus[bundleHash] = BundleStatus.FullyExecuted;

        _executeCalls({
            _sourceChainId: _proof.chainId,
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _executeAllCalls: true,
            _callStatus: new CallStatus[](0)
        });
    }

    function verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public {
        _verifyBundle(_bundle, _proof);
        InteropBundle memory interopBundle = abi.decode(_bundle, (InteropBundle));
        bytes32 bundleHash = _calculateBundleHash(
            _proof.chainId,
            interopBundle.sendingBlockNumber,
            _proof.l2MessageIndex,
            _bundle
        );
        BundleStatus status = bundleStatus[bundleHash];
        if (status != BundleStatus.Unreceived && status != BundleStatus.Verified) {
            revert BundleAlreadyProcessed(bundleHash);
        }
        bundleStatus[bundleHash] = BundleStatus.Verified;
    }

    function unbundleBundle(
        uint256 _sourceChainId,
        uint256 _l2MessageIndex,
        bytes memory _bundle,
        CallStatus[] calldata _callStatus
    ) public {
        InteropBundle memory interopBundle = abi.decode(_bundle, (InteropBundle));
        bytes32 bundleHash = _calculateBundleHash({
            _sourceChainId: _sourceChainId,
            _sendingBlockNumber: interopBundle.sendingBlockNumber,
            _l2MessageIndex: _l2MessageIndex,
            _bundle: _bundle
        });

        BundleStatus status = bundleStatus[bundleHash];
        if (status == BundleStatus.Unreceived || status == BundleStatus.FullyExecuted) {
            revert CanNotUnbundle(bundleHash);
        }
        bundleStatus[bundleHash] = BundleStatus.Unbundled;

        _executeCalls({
            _sourceChainId: _sourceChainId,
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _executeAllCalls: true,
            _callStatus: _callStatus
        });
    }

    /*//////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    function _calculateBundleHash(
        uint256 _sourceChainId,
        uint256 _sendingBlockNumber,
        uint256 _l2MessageIndex,
        bytes memory _bundle
    ) internal pure returns (bytes32 bundleHash) {
        bundleHash = keccak256(abi.encode(_sourceChainId, _sendingBlockNumber, _l2MessageIndex, _bundle));
    }

    function _executeCalls(
        uint256 _sourceChainId,
        bytes32 _bundleHash,
        InteropBundle memory _interopBundle,
        bool _executeAllCalls,
        CallStatus[] memory _callStatus
    ) internal {
        uint256 callsLength = _interopBundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            if (!_executeAllCalls) {
                if (_callStatus[i] != CallStatus.Executed) {
                    continue;
                }
                require(callStatus[_bundleHash][i] == CallStatus.Unprocessed, CallNotExecutable(_bundleHash, i));
            }
            InteropCall memory interopCall = _interopBundle.calls[i];

            L2_BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), interopCall.value);
            // slither-disable-next-line arbitrary-send-eth
            bytes4 selector = IERC7786Receiver(interopCall.to).executeMessage{value: interopCall.value}({
                messageId: _bundleHash,
                sourceChain: _sourceChainId,
                sender: interopCall.from,
                payload: interopCall.data,
                attributes: new bytes[](0)
            }); // attributes are not supported yet
            if (selector != IERC7786Receiver.executeMessage.selector) {
                revert InvalidSelector(selector);
            }
        }
    }

    function _verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) internal view {
        _proof.message.data = bytes.concat(BUNDLE_IDENTIFIER, _bundle);
        bool isIncluded = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
            _chainId: _proof.chainId,
            _blockOrBatchNumber: _proof.l1BatchNumber,
            _index: _proof.l2MessageIndex,
            _message: _proof.message,
            _proof: _proof.proof
        });
        if (!isIncluded) {
            revert MessageNotIncluded();
        }
    }
}
