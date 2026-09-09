// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {
    RLP_SHORT_STRING_PREFIX,
    RLP_SHORT_LIST_PREFIX,
    RLP_ADDRESS_PREFIX,
    RLP_ENCODED_ADDRESS_LENGTH
} from "../Config.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for working with L2 contracts on L1.
 */
library L2ContractHelper {
    /// @notice Calculates the address of a contract deployed with the EVM `CREATE` opcode.
    /// @param _sender The account that deploys the contract.
    /// @param _senderNonce The sender's EVM account nonce consumed by the deployment.
    function computeCreateAddress(address _sender, uint256 _senderNonce) internal pure returns (address) {
        bytes memory encodedNonce;
        if (_senderNonce == 0) {
            encodedNonce = abi.encodePacked(RLP_SHORT_STRING_PREFIX);
        } else if (_senderNonce < RLP_SHORT_STRING_PREFIX) {
            encodedNonce = abi.encodePacked(uint8(_senderNonce));
        } else {
            uint256 nonceLength;
            uint256 nonce = _senderNonce;
            while (nonce != 0) {
                ++nonceLength;
                nonce >>= 8;
            }

            encodedNonce = new bytes(nonceLength + 1);
            encodedNonce[0] = bytes1(uint8(RLP_SHORT_STRING_PREFIX + nonceLength));
            for (uint256 i = 0; i < nonceLength; ++i) {
                encodedNonce[nonceLength - i] = bytes1(uint8(_senderNonce >> (8 * i)));
            }
        }

        // The RLP payload is 21 bytes for the encoded sender plus at most 33 bytes for a uint256
        // nonce, so its list prefix always fits in the single-byte short-list form.
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(uint8(RLP_SHORT_LIST_PREFIX + RLP_ENCODED_ADDRESS_LENGTH + encodedNonce.length)),
                RLP_ADDRESS_PREFIX,
                _sender,
                encodedNonce
            )
        );

        return address(uint160(uint256(hash)));
    }
}
