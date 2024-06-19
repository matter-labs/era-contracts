// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {IERC1271Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC1271Upgradeable.sol";

import {SignatureDecoder} from "../libraries/SignatureDecoder.sol";
import {ValidationHandler} from "./ValidationHandler.sol";
import {EIP712} from "../helpers/EIP712.sol";

/**
 * @title ERC1271Handler
 * @notice Contract which provides ERC1271 signature validation
 * @author https://getclave.io
 */
abstract contract ERC1271Handler is
    IERC1271Upgradeable,
    EIP712("Clave1271", "1.0.0"),
    ValidationHandler
{
    struct ClaveMessage {
        bytes32 signedHash;
    }

    bytes32 constant _CLAVE_MESSAGE_TYPEHASH =
        keccak256("ClaveMessage(bytes32 signedHash)");

    bytes4 private constant _ERC1271_MAGIC = 0x1626ba7e;

    /**
     * @dev Should return whether the signature provided is valid for the provided data
     * @param signedHash bytes32                   - Hash of the data that is signed
     * @param signatureAndValidator bytes calldata - Validator address concatenated to signature
     * @return magicValue bytes4 - Magic value if the signature is valid, 0 otherwise
     */
    function isValidSignature(
        bytes32 signedHash,
        bytes memory signatureAndValidator
    ) public view override returns (bytes4 magicValue) {
        (bytes memory signature, address validator) = SignatureDecoder
            .decodeSignatureNoHookData(signatureAndValidator);

        bytes32 eip712Hash = _hashTypedDataV4(
            _claveMessageHash(ClaveMessage(signedHash))
        );

        bool valid = _handleValidation(validator, eip712Hash, signature);

        magicValue = valid ? _ERC1271_MAGIC : bytes4(0);
    }

    /**
     * @notice Returns the EIP-712 hash of the Clave message
     * @param claveMessage ClaveMessage calldata - The message containing signedHash
     * @return bytes32 - EIP712 hash of the message
     */
    function getEip712Hash(
        ClaveMessage calldata claveMessage
    ) external view returns (bytes32) {
        return _hashTypedDataV4(_claveMessageHash(claveMessage));
    }

    /**
     * @notice Returns the typehash for the clave message struct
     * @return bytes32 - Clave message typehash
     */
    function claveMessageTypeHash() external pure returns (bytes32) {
        return _CLAVE_MESSAGE_TYPEHASH;
    }

    function _claveMessageHash(
        ClaveMessage memory claveMessage
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(_CLAVE_MESSAGE_TYPEHASH, claveMessage.signedHash)
            );
    }
}
