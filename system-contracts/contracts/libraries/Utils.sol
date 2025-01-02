// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {EfficientCall} from "./EfficientCall.sol";
import {RLPEncoder} from "./RLPEncoder.sol";
import {MalformedBytecode, BytecodeError, Overflow} from "../SystemContractErrors.sol";
import {ERA_VM_BYTECODE_FLAG, EVM_BYTECODE_FLAG, CREATE2_EVM_PREFIX} from "../Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @dev Common utilities used in ZKsync system contracts
 */
library Utils {
    /// @dev Bit mask of bytecode hash "isConstructor" marker
    bytes32 internal constant IS_CONSTRUCTOR_BYTECODE_HASH_BIT_MASK =
        0x00ff000000000000000000000000000000000000000000000000000000000000;

    /// @dev Bit mask to set the "isConstructor" marker in the bytecode hash
    bytes32 internal constant SET_IS_CONSTRUCTOR_MARKER_BIT_MASK =
        0x0001000000000000000000000000000000000000000000000000000000000000;

    function safeCastToU128(uint256 _x) internal pure returns (uint128) {
        if (_x > type(uint128).max) {
            revert Overflow();
        }

        return uint128(_x);
    }

    function safeCastToU32(uint256 _x) internal pure returns (uint32) {
        if (_x > type(uint32).max) {
            revert Overflow();
        }

        return uint32(_x);
    }

    function safeCastToU24(uint256 _x) internal pure returns (uint24) {
        if (_x > type(uint24).max) {
            revert Overflow();
        }

        return uint24(_x);
    }

    /// @return If this bytecode hash for EVM contract or not
    function isCodeHashEVM(bytes32 _bytecodeHash) internal pure returns (bool) {
        return (uint8(_bytecodeHash[0]) == EVM_BYTECODE_FLAG);
    }

    /// @return codeLengthInBytes The bytecode length in bytes
    function bytecodeLenInBytes(bytes32 _bytecodeHash) internal pure returns (uint256 codeLengthInBytes) {
        unchecked {
            uint256 decodedCodeLength = uint256(uint8(_bytecodeHash[2])) * 256 + uint256(uint8(_bytecodeHash[3]));
            if (isCodeHashEVM(_bytecodeHash)) {
                // length is encoded in bytes
                codeLengthInBytes = decodedCodeLength;
            } else {
                // length is encoded in words
                codeLengthInBytes = decodedCodeLength << 5; // * 32
            }
        }
    }

    /// @return codeLengthInWords The bytecode length in machine words
    function bytecodeLenInWords(bytes32 _bytecodeHash) internal pure returns (uint256 codeLengthInWords) {
        unchecked {
            uint256 decodedCodeLength = uint256(uint8(_bytecodeHash[2])) * 256 + uint256(uint8(_bytecodeHash[3]));
            if (isCodeHashEVM(_bytecodeHash)) {
                // length is encoded in bytes
                codeLengthInWords = (decodedCodeLength + 31) / 32; // rounded up
            } else {
                // length is encoded in words
                codeLengthInWords = decodedCodeLength;
            }
        }
    }

    /// @notice Denotes whether bytecode hash corresponds to a contract that already constructed
    function isContractConstructed(bytes32 _bytecodeHash) internal pure returns (bool) {
        return _bytecodeHash[1] == 0x00;
    }

    /// @notice Denotes whether bytecode hash corresponds to a contract that is on constructor or has already been constructed
    function isContractConstructing(bytes32 _bytecodeHash) internal pure returns (bool) {
        return _bytecodeHash[1] == 0x01;
    }

    /// @notice Sets "isConstructor" flag to TRUE for the bytecode hash
    /// @param _bytecodeHash The bytecode hash for which it is needed to set the constructing flag
    /// @return The bytecode hash with "isConstructor" flag set to TRUE
    function constructingBytecodeHash(bytes32 _bytecodeHash) internal pure returns (bytes32) {
        // Clear the "isConstructor" marker and set it to 0x01.
        return constructedBytecodeHash(_bytecodeHash) | SET_IS_CONSTRUCTOR_MARKER_BIT_MASK;
    }

    /// @notice Sets "isConstructor" flag to FALSE for the bytecode hash
    /// @param _bytecodeHash The bytecode hash for which it is needed to set the constructing flag
    /// @return The bytecode hash with "isConstructor" flag set to FALSE
    function constructedBytecodeHash(bytes32 _bytecodeHash) internal pure returns (bytes32) {
        return _bytecodeHash & ~IS_CONSTRUCTOR_BYTECODE_HASH_BIT_MASK;
    }

    uint256 internal constant MAX_BYTECODE_LENGTH = (2 ** 16) - 1;

    /// @notice Validate the bytecode format and calculate its hash.
    /// @param _bytecode The bytecode to hash.
    /// @return hashedBytecode The 32-byte hash of the bytecode.
    /// Note: The function reverts the execution if the bytecode has non expected format:
    /// - Bytecode bytes length is not a multiple of 32
    /// - Bytecode bytes length is not less than 2^21 bytes (2^16 words)
    /// - Bytecode words length is not odd
    function hashL2Bytecode(bytes calldata _bytecode) internal view returns (bytes32 hashedBytecode) {
        // Note that the length of the bytecode must be provided in 32-byte words.
        if (_bytecode.length % 32 != 0) {
            revert MalformedBytecode(BytecodeError.Length);
        }

        uint256 lengthInWords = _bytecode.length / 32;
        // bytecode length must be less than 2^16 words
        if (lengthInWords > MAX_BYTECODE_LENGTH) {
            revert MalformedBytecode(BytecodeError.NumberOfWords);
        }
        // bytecode length in words must be odd
        if (lengthInWords % 2 == 0) {
            revert MalformedBytecode(BytecodeError.WordsMustBeOdd);
        }
        hashedBytecode =
            EfficientCall.sha(_bytecode) &
            0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        // Setting the version of the hash
        hashedBytecode = (hashedBytecode | bytes32(uint256(ERA_VM_BYTECODE_FLAG) << 248));
        // Setting the length
        hashedBytecode = hashedBytecode | bytes32(lengthInWords << 224);
    }

    /// @notice Validate the bytecode format and calculate its hash.
    /// @param _evmBytecodeLen The length of original EVM bytecode in bytes
    /// @param _paddedBytecode The padded EVM bytecode to hash.
    /// @return hashedEVMBytecode The 32-byte hash of the EVM bytecode.
    /// Note: The function reverts the execution if the bytecode has non expected format:
    /// - Bytecode bytes length is not a multiple of 32
    /// - Bytecode bytes length is greater than 2^16 - 1 bytes
    /// - Bytecode words length is not odd
    function hashEVMBytecode(
        uint256 _evmBytecodeLen,
        bytes calldata _paddedBytecode
    ) internal view returns (bytes32 hashedEVMBytecode) {
        // Note that the length of the bytecode must be provided in 32-byte words.
        if (_paddedBytecode.length % 32 != 0) {
            revert MalformedBytecode(BytecodeError.Length);
        }

        if (_evmBytecodeLen > _paddedBytecode.length) {
            revert MalformedBytecode(BytecodeError.EvmBytecodeLength);
        }

        // bytecode length must be less than 2^16 bytes
        if (_evmBytecodeLen > MAX_BYTECODE_LENGTH) {
            revert MalformedBytecode(BytecodeError.EvmBytecodeLengthTooBig);
        }

        uint256 lengthInWords = _paddedBytecode.length / 32;
        // bytecode length in words must be odd
        if (lengthInWords % 2 == 0) {
            revert MalformedBytecode(BytecodeError.WordsMustBeOdd);
        }

        hashedEVMBytecode =
            EfficientCall.sha(_paddedBytecode) &
            0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

        // Setting the version of the hash
        hashedEVMBytecode = (hashedEVMBytecode | bytes32(uint256(EVM_BYTECODE_FLAG) << 248));
        hashedEVMBytecode = hashedEVMBytecode | bytes32(_evmBytecodeLen << 224);
    }

    /// @notice Calculates the address of a deployed contract via create2 on the EVM
    /// @param _sender The account that deploys the contract.
    /// @param _salt The create2 salt.
    /// @param _bytecodeHash The hash of the init code of the new contract.
    /// @return newAddress The derived address of the account.
    function getNewAddressCreate2EVM(
        address _sender,
        bytes32 _salt,
        bytes32 _bytecodeHash
    ) internal pure returns (address newAddress) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(CREATE2_EVM_PREFIX), _sender, _salt, _bytecodeHash));

        newAddress = address(uint160(uint256(hash)));
    }

    /// @notice Calculates the address of a deployed contract via create
    /// @param _sender The account that deploys the contract.
    /// @param _senderNonce The deploy nonce of the sender's account.
    function getNewAddressCreateEVM(address _sender, uint256 _senderNonce) internal pure returns (address newAddress) {
        bytes memory addressEncoded = RLPEncoder.encodeAddress(_sender);
        bytes memory nonceEncoded = RLPEncoder.encodeUint256(_senderNonce);

        uint256 listLength = addressEncoded.length + nonceEncoded.length;
        bytes memory listLengthEncoded = RLPEncoder.encodeListLen(uint64(listLength));

        bytes memory digest = bytes.concat(listLengthEncoded, addressEncoded, nonceEncoded);

        bytes32 hash = keccak256(digest);
        newAddress = address(uint160(uint256(hash)));
    }
}
