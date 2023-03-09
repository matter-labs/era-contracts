// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IL1Messenger.sol";
import "./libraries/SystemContractHelper.sol";
import "./libraries/EfficientCall.sol";

/**
 * @author Matter Labs
 * @notice Smart contract for sending arbitrary length messages to L1
 * @dev by default ZkSync can send fixed length messages on L1.
 * A fixed length message has 4 parameters `senderAddress` `isService`, `key`, `value`,
 * the first one is taken from the context, the other three are chosen by the sender.
 * @dev To send a variable length message we use this trick:
 * - This system contract accepts a arbitrary length message and sends a fixed length message with
 * parameters `senderAddress == this`, `marker == true`, `key == msg.sender`, `value == keccak256(message)`.
 * - The contract on L1 accepts all sent messages and if the message came from this system contract
 * it requires that the preimage of `value` be provided.
 */
contract L1Messenger is IL1Messenger {
    function sendToL1(bytes calldata _message) external override returns (bytes32 hash) {
        hash = EfficientCall.keccak(_message);

        // Get cost of one byte pubdata in gas from context.
        uint256 meta = SystemContractHelper.getZkSyncMetaBytes();
        uint32 gasPerPubdataBytes = SystemContractHelper.getGasPerPubdataByteFromMeta(meta);

        // Calculate how many bytes of calldata will need to be transferred to L1.
        // We published the data as ABI-encoded `bytes`, so we pay for:
        // - message length in bytes, rounded up to a multiple of 32
        // - 32 bytes of encoded offset
        // - 32 bytes of encoded length

        uint256 pubdataLen;
        unchecked {
            pubdataLen = ((_message.length + 31) / 32) * 32 + 64;
        }
        uint256 gasToPay = pubdataLen * gasPerPubdataBytes;

        // Call precompile to burn gas to cover the cost of publishing pubdata to L1.
        uint256 precompileParams = SystemContractHelper.packPrecompileParams(0, 0, 0, 0, 0);
        bool precompileCallSuccess = SystemContractHelper.precompileCall(
            precompileParams,
            Utils.safeCastToU32(gasToPay)
        );
        require(precompileCallSuccess);

        SystemContractHelper.toL1(true, bytes32(uint256(uint160(msg.sender))), hash);

        emit L1MessageSent(msg.sender, hash, _message);
    }
}
