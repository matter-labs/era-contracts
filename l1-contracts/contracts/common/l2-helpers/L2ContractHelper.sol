// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

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
            encodedNonce = hex"80";
        } else if (_senderNonce <= 0x7f) {
            encodedNonce = abi.encodePacked(uint8(_senderNonce));
        } else {
            uint256 nonceLength;
            uint256 nonce = _senderNonce;
            while (nonce != 0) {
                ++nonceLength;
                nonce >>= 8;
            }

            encodedNonce = new bytes(nonceLength + 1);
            encodedNonce[0] = bytes1(uint8(0x80 + nonceLength));
            for (uint256 i = 0; i < nonceLength; ++i) {
                encodedNonce[nonceLength - i] = bytes1(uint8(_senderNonce >> (8 * i)));
            }
        }

        // The RLP payload is 21 bytes for the encoded sender plus at most 33 bytes for a uint256
        // nonce, so its list prefix always fits in the single-byte short-list form.
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(uint8(0xc0 + 21 + encodedNonce.length)), hex"94", _sender, encodedNonce)
        );

        return address(uint160(uint256(hash)));
    }

    /// @notice Returns the observable ZKsync OS hashes of the supplied EVM bytecodes.
    function hashFactoryDeps(bytes[] memory _factoryDeps) internal pure returns (uint256[] memory hashedFactoryDeps) {
        uint256 factoryDepsLen = _factoryDeps.length;
        hashedFactoryDeps = new uint256[](factoryDepsLen);
        for (uint256 i = 0; i < factoryDepsLen; ++i) {
            // The observable bytecode hash under ZKsync OS is keccak256.
            hashedFactoryDeps[i] = uint256(keccak256(_factoryDeps[i]));
        }
    }
}

/// @notice Structure used to represent a ZKsync transaction.
struct Transaction {
    // The type of the transaction.
    uint256 txType;
    // The caller.
    uint256 from;
    // The callee.
    uint256 to;
    // The gasLimit to pass with the transaction.
    // It has the same meaning as Ethereum's gasLimit.
    uint256 gasLimit;
    // The maximum amount of gas the user is willing to pay for a byte of pubdata.
    uint256 gasPerPubdataByteLimit;
    // The maximum fee per gas that the user is willing to pay.
    // It is akin to EIP1559's maxFeePerGas.
    uint256 maxFeePerGas;
    // The maximum priority fee per gas that the user is willing to pay.
    // It is akin to EIP1559's maxPriorityFeePerGas.
    uint256 maxPriorityFeePerGas;
    // The transaction's paymaster. If there is no paymaster, it is equal to 0.
    uint256 paymaster;
    // The nonce of the transaction.
    uint256 nonce;
    // The value to pass with the transaction.
    uint256 value;
    // In the future, we might want to add some
    // new fields to the struct. The `txData` struct
    // is to be passed to account and any changes to its structure
    // would mean a breaking change to these accounts. In order to prevent this,
    // we should keep some fields as "reserved".
    // It is also recommended that their length is fixed, since
    // it would allow easier proof integration (in case we will need
    // some special circuit for preprocessing transactions).
    uint256[4] reserved;
    // The transaction's calldata.
    bytes data;
    // The signature of the transaction.
    bytes signature;
    // The observable hashes of bytecodes that must be published on L1
    // with the inclusion of this transaction. Note, that a bytecode has been published
    // before, the user won't pay fees for its republishing.
    bytes32[] factoryDeps;
    // The input to the paymaster.
    bytes paymasterInput;
    // Reserved dynamic type for the future use-case. Using it should be avoided,
    // But it is still here, just in case we want to enable some additional functionality.
    bytes reservedDynamic;
}
