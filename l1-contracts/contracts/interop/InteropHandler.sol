// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_MESSAGE_VERIFICATION} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IInteropHandler} from "./IInteropHandler.sol";
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, MessageInclusionProof} from "../common/Messaging.sol";
import {IERC7786Receiver} from "./IERC7786Receiver.sol";
error MessageNotIncluded();
error BundleAlreadyExecuted(bytes32 bundleHash);

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that handles the interop bundles.
 */
contract InteropHandler is IInteropHandler {
    bytes32 public bytecodeHash;

    /// @notice The balances of the users.
    mapping(bytes32 bundleHash => bool bundleExecuted) public bundleExecuted;

    error InvalidSelector(bytes4 selector);
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public {
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
        bytes32 bundleHash = keccak256(
            abi.encode(_proof.chainId, _proof.l1BatchNumber, _proof.l2MessageIndex, _bundle)
        );
        if (bundleExecuted[bundleHash]) {
            revert BundleAlreadyExecuted(bundleHash);
        }
        bundleExecuted[bundleHash] = true;

        InteropBundle memory interopBundle = abi.decode(_bundle, (InteropBundle));

        uint256 callsLength = interopBundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            InteropCall memory interopCall = interopBundle.calls[i];

            L2_BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), interopCall.value);
            bytes4 selector = IERC7786Receiver(interopCall.to).executeMessage{value: interopCall.value}({
                messageId: bundleHash,
                sourceChain: _proof.chainId,
                sender: interopCall.from,
                payload: interopCall.data,
                attributes: new bytes[](0)
            }); // attributes are not supported yet
            if (selector != IERC7786Receiver.executeMessage.selector) {
                revert InvalidSelector(selector);
            }
        }
    }
}
