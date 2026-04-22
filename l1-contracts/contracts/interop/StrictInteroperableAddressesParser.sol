// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";
import {ERC7930_V1_MIN_LENGTH} from "./InteropConstants.sol";

/// @title StrictInteroperableAddressesParser
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Strict wrappers around the parse helpers from the vendored
/// {InteroperableAddress} library. The vendored library accepts inputs with trailing bytes
/// beyond the declared chainReference/address, because it checks
/// `self.length < 0x06 + chainReferenceLength + addrLength` (strictly less than) as the
/// final length guard. For protocol inputs we want to reject such inputs so that a single
/// ERC-7930 payload has a unique encoding and cannot be extended with arbitrary bytes.
///
/// Each wrapper first runs the strict length check (minimum length, then chainReferenceLength,
/// then addressLength, then exact-length equality) and only delegates to the vendor parser
/// once the length is known to match the declared layout exactly. Because strict equality
/// implies the vendor's `<` check passes, delegation is always safe.
library StrictInteroperableAddressesParser {
    /// @notice Returns true iff `_self` has a length that exactly matches the declared
    /// ERC-7930 v1 layout: `ERC7930_V1_MIN_LENGTH + chainReferenceLength + addressLength`.
    /// @dev The caller is responsible for providing calldata whose first bytes are safe to
    /// read as the ERC-7930 header; we only check length before dereferencing.
    function _hasStrictLengthCalldata(bytes calldata _self) private pure returns (bool) {
        if (_self.length < ERC7930_V1_MIN_LENGTH) return false;
        uint256 chainReferenceLength = uint8(_self[0x04]);
        if (_self.length < ERC7930_V1_MIN_LENGTH + chainReferenceLength) return false;
        uint256 addressLength = uint8(_self[0x05 + chainReferenceLength]);
        return _self.length == ERC7930_V1_MIN_LENGTH + chainReferenceLength + addressLength;
    }

    /// @notice Memory-variant of {_hasStrictLengthCalldata}.
    function _hasStrictLengthMemory(bytes memory _self) private pure returns (bool) {
        if (_self.length < ERC7930_V1_MIN_LENGTH) return false;
        uint256 chainReferenceLength = uint8(_self[0x04]);
        if (_self.length < ERC7930_V1_MIN_LENGTH + chainReferenceLength) return false;
        uint256 addressLength = uint8(_self[0x05 + chainReferenceLength]);
        return _self.length == ERC7930_V1_MIN_LENGTH + chainReferenceLength + addressLength;
    }

    /// @notice Strict variant of {InteroperableAddress-parseV1Calldata}. Reverts with
    /// `InteroperableAddressParsingError` if the payload has trailing bytes beyond the
    /// declared layout.
    function parseV1Calldata(
        bytes calldata _self
    ) internal pure returns (bytes2 chainType, bytes calldata chainReference, bytes calldata addr) {
        require(_hasStrictLengthCalldata(_self), InteroperableAddress.InteroperableAddressParsingError(_self));
        return InteroperableAddress.parseV1Calldata(_self);
    }

    /// @notice Strict variant of {InteroperableAddress-parseEvmV1}. Reverts with
    /// `InteroperableAddressParsingError` if the payload has trailing bytes beyond the
    /// declared layout.
    function parseEvmV1(bytes memory _self) internal pure returns (uint256 chainId, address addr) {
        require(_hasStrictLengthMemory(_self), InteroperableAddress.InteroperableAddressParsingError(_self));
        return InteroperableAddress.parseEvmV1(_self);
    }

    /// @notice Strict variant of {InteroperableAddress-parseEvmV1Calldata}. Reverts with
    /// `InteroperableAddressParsingError` if the payload has trailing bytes beyond the
    /// declared layout.
    function parseEvmV1Calldata(bytes calldata _self) internal pure returns (uint256 chainId, address addr) {
        require(_hasStrictLengthCalldata(_self), InteroperableAddress.InteroperableAddressParsingError(_self));
        return InteroperableAddress.parseEvmV1Calldata(_self);
    }
}
