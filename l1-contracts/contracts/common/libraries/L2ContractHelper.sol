// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {BytecodeError, MalformedBytecode, LengthIsNotDivisibleBy32} from "../L1ContractErrors.sol";

import {UncheckedMath} from "./UncheckedMath.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../L2ContractAddresses.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Interface for the contract that is used to deploy contracts on L2.
 */
interface IContractDeployer {
    /// @notice A struct that describes a forced deployment on an address.
    /// @param bytecodeHash The bytecode hash to put on an address.
    /// @param newAddress The address on which to deploy the bytecodehash to.
    /// @param callConstructor Whether to run the constructor on the force deployment.
    /// @param value The `msg.value` with which to initialize a contract.
    /// @param input The constructor calldata.
    struct ForceDeployment {
        bytes32 bytecodeHash;
        address newAddress;
        bool callConstructor;
        uint256 value;
        bytes input;
    }

    /// @notice This method is to be used only during an upgrade to set bytecodes on specific addresses.
    /// @param _deployParams A set of parameters describing force deployment.
    function forceDeployOnAddresses(ForceDeployment[] calldata _deployParams) external payable;

    /// @notice Creates a new contract at a determined address using the `CREATE2` salt on L2
    /// @param _salt a unique value to create the deterministic address of the new contract
    /// @param _bytecodeHash the bytecodehash of the new contract to be deployed
    /// @param _input the calldata to be sent to the constructor of the new contract
    function create2(bytes32 _salt, bytes32 _bytecodeHash, bytes calldata _input) external returns (address);
}

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for working with L2 contracts on L1.
 */
library L2ContractHelper {
    using UncheckedMath for uint256;

    /// @dev The prefix used to create CREATE2 addresses.
    bytes32 private constant CREATE2_PREFIX = keccak256("zksyncCreate2");

    /// @dev Prefix used during derivation of account addresses using CREATE
    /// @dev keccak256("zksyncCreate")
    bytes32 private constant CREATE_PREFIX = 0x63bae3a9951d38e8a3fbb7b70909afc1200610fc5bc55ade242f815974674f23;

    /// @notice Sends L2 -> L1 arbitrary-long message through the system contract messenger.
    /// @param _message Data to be sent to L1.
    /// @return keccak256 hash of the sent message.
    function sendMessageToL1(bytes memory _message) internal returns (bytes32) {
        return L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR.sendToL1(_message);
    }

    /// @notice Validate the bytecode format and calculate its hash.
    /// @param _bytecode The bytecode to hash.
    /// @return hashedBytecode The 32-byte hash of the bytecode.
    /// Note: The function reverts the execution if the bytecode has non expected format:
    /// - Bytecode bytes length is not a multiple of 32
    /// - Bytecode bytes length is not less than 2^21 bytes (2^16 words)
    /// - Bytecode words length is not odd
    function hashL2Bytecode(bytes memory _bytecode) internal pure returns (bytes32 hashedBytecode) {
        // Note that the length of the bytecode must be provided in 32-byte words.
        if (_bytecode.length % 32 != 0) {
            revert LengthIsNotDivisibleBy32(_bytecode.length);
        }

        uint256 bytecodeLenInWords = _bytecode.length / 32;
        // bytecode length must be less than 2^16 words
        if (bytecodeLenInWords >= 2 ** 16) {
            revert MalformedBytecode(BytecodeError.NumberOfWords);
        }
        // bytecode length in words must be odd
        if (bytecodeLenInWords % 2 == 0) {
            revert MalformedBytecode(BytecodeError.WordsMustBeOdd);
        }
        hashedBytecode = sha256(_bytecode) & 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        // Setting the version of the hash
        hashedBytecode = (hashedBytecode | bytes32(uint256(1 << 248)));
        // Setting the length
        hashedBytecode = hashedBytecode | bytes32(bytecodeLenInWords << 224);
    }

    /// @notice Validate the bytecode format and calculate its hash.
    /// @param _bytecode The bytecode to hash.
    /// @return hashedBytecode The 32-byte hash of the bytecode.
    /// Note: The function reverts the execution if the bytecode has non expected format:
    /// - Bytecode bytes length is not a multiple of 32
    /// - Bytecode bytes length is not less than 2^21 bytes (2^16 words)
    /// - Bytecode words length is not odd
    function hashL2BytecodeCalldata(bytes calldata _bytecode) internal pure returns (bytes32 hashedBytecode) {
        // Note that the length of the bytecode must be provided in 32-byte words.
        if (_bytecode.length % 32 != 0) {
            revert LengthIsNotDivisibleBy32(_bytecode.length);
        }

        uint256 bytecodeLenInWords = _bytecode.length / 32;
        // bytecode length must be less than 2^16 words
        if (bytecodeLenInWords >= 2 ** 16) {
            revert MalformedBytecode(BytecodeError.NumberOfWords);
        }
        // bytecode length in words must be odd
        if (bytecodeLenInWords % 2 == 0) {
            revert MalformedBytecode(BytecodeError.WordsMustBeOdd);
        }
        hashedBytecode = sha256(_bytecode) & 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        // Setting the version of the hash
        hashedBytecode = (hashedBytecode | bytes32(uint256(1 << 248)));
        // Setting the length
        hashedBytecode = hashedBytecode | bytes32(bytecodeLenInWords << 224);
    }

    /// @notice Validates the format of the given bytecode hash.
    /// @dev Due to the specification of the L2 bytecode hash, not every 32 bytes could be a legit bytecode hash.
    /// @dev The function reverts on invalid bytecode hash format.
    /// @param _bytecodeHash The hash of the bytecode to validate.
    function validateBytecodeHash(bytes32 _bytecodeHash) internal pure {
        uint8 version = uint8(_bytecodeHash[0]);
        // Incorrectly formatted bytecodeHash
        if (version != 1 || _bytecodeHash[1] != bytes1(0)) {
            revert MalformedBytecode(BytecodeError.Version);
        }

        // Code length in words must be odd
        if (bytecodeLen(_bytecodeHash) % 2 == 0) {
            revert MalformedBytecode(BytecodeError.WordsMustBeOdd);
        }
    }

    /// @notice Returns the length of the bytecode associated with the given hash.
    /// @param _bytecodeHash The hash of the bytecode.
    /// @return codeLengthInWords The length of the bytecode in words.
    function bytecodeLen(bytes32 _bytecodeHash) internal pure returns (uint256 codeLengthInWords) {
        codeLengthInWords = uint256(uint8(_bytecodeHash[2])) * 256 + uint256(uint8(_bytecodeHash[3]));
    }

    /// @notice Computes the create2 address for a Layer 2 contract.
    /// @param _sender The address of the sender.
    /// @param _salt The salt value to use in the create2 address computation.
    /// @param _bytecodeHash The contract bytecode hash.
    /// @param _constructorInputHash The hash of the constructor input data.
    /// @return The create2 address of the contract.
    /// NOTE: L2 create2 derivation is different from L1 derivation!
    function computeCreate2Address(
        address _sender,
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes32 _constructorInputHash
    ) internal pure returns (address) {
        bytes32 senderBytes = bytes32(uint256(uint160(_sender)));
        bytes32 data = keccak256(
            // solhint-disable-next-line func-named-parameters
            bytes.concat(CREATE2_PREFIX, senderBytes, _salt, _bytecodeHash, _constructorInputHash)
        );

        return address(uint160(uint256(data)));
    }

    /// @notice Calculates the address of a deployed contract via create
    /// @param _sender The account that deploys the contract.
    /// @param _senderNonce The deploy nonce of the sender's account.
    /// NOTE: L2 create derivation is different from L1 derivation!
    function computeCreateAddress(address _sender, uint256 _senderNonce) internal pure returns (address) {
        // No collision is possible with the Ethereum's CREATE, since
        // the prefix begins with 0x63....
        bytes32 hash = keccak256(
            bytes.concat(CREATE_PREFIX, bytes32(uint256(uint160(_sender))), bytes32(_senderNonce))
        );

        return address(uint160(uint256(hash)));
    }

    /// @notice Hashes the L2 bytecodes and returns them in the format in which they are processed by the bootloader
    function hashFactoryDeps(bytes[] memory _factoryDeps) internal pure returns (uint256[] memory hashedFactoryDeps) {
        uint256 factoryDepsLen = _factoryDeps.length;
        hashedFactoryDeps = new uint256[](factoryDepsLen);
        for (uint256 i = 0; i < factoryDepsLen; i = i.uncheckedInc()) {
            bytes32 hashedBytecode = hashL2Bytecode(_factoryDeps[i]);

            // Store the resulting hash sequentially in words.
            assembly {
                mstore(add(hashedFactoryDeps, mul(add(i, 1), 32)), hashedBytecode)
            }
        }
    }
}
