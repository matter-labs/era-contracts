// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {Errors} from "../libraries/Errors.sol";

library SignatureDecoder {
    // Decode transaction.signature into signature, validator and hook data
    function decodeSignature(
        bytes calldata txSignature
    )
        internal
        pure
        returns (
            bytes memory signature,
            address validator,
            bytes[] memory hookData
        )
    {
        (signature, validator, hookData) = abi.decode(
            txSignature,
            (bytes, address, bytes[])
        );
    }

    // Decode transaction.signature into hook data
    function decodeSignatureOnlyHookData(
        bytes calldata txSignature
    ) internal pure returns (bytes[] memory hookData) {
        (hookData) = abi.decode(txSignature, (bytes[]));
    }

    // Decode signature into signature and validator
    function decodeSignatureNoHookData(
        bytes memory signatureAndValidator
    ) internal pure returns (bytes memory signature, address validator) {
        (signature, validator) = abi.decode(
            signatureAndValidator,
            (bytes, address)
        );
    }
}
