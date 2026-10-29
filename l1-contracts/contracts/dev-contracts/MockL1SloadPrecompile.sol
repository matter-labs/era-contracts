// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {L2_INTEROP_ROOT_STORAGE} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {L1SLOAD_MAX_ANCHOR_AGE, L1SLOAD_MAX_KEYS} from "../common/Config.sol";

/// @title MockL1SloadPrecompile
/// @notice Stand-in for the ZKsync OS L1SLOAD precompile on EVMs that don't have it. It serves the values last set
/// with {setL1StorageValues}, and fails like the precompile, consuming the gas passed to it, on malformed input and on
/// a missing or stale anchor.
/// @dev It doesn't check the values against the anchor, nor model the precompile's per-transaction read cap.
contract MockL1SloadPrecompile {
    uint256 internal constant ADDRESS_LENGTH = 20;
    uint256 internal constant WORD_LENGTH = 32;

    /// @notice The value served for `_key` of `_l1Contract`.
    mapping(address l1Contract => mapping(bytes32 key => bytes32 value)) public l1StorageValue;

    /// @notice Sets the values served for storage slots of an L1 contract.
    /// @param _l1Contract The L1 contract.
    /// @param _keys The storage slots.
    /// @param _values The values, in the order of `_keys`.
    function setL1StorageValues(address _l1Contract, bytes32[] calldata _keys, bytes32[] calldata _values) external {
        require(_keys.length == _values.length);
        for (uint256 i = 0; i < _keys.length; ++i) {
            l1StorageValue[_l1Contract][_keys[i]] = _values[i];
        }
    }

    fallback(bytes calldata _input) external returns (bytes memory output) {
        (, bytes32 anchorBlockHash, uint256 anchorTimestamp) = L2_INTEROP_ROOT_STORAGE.l1Anchor();
        // `block.timestamp > anchorTimestamp + L1SLOAD_MAX_ANCHOR_AGE` without overflow, as ZKsync OS saturates the sum.
        bool stale = block.timestamp > anchorTimestamp && block.timestamp - anchorTimestamp > L1SLOAD_MAX_ANCHOR_AGE;
        uint256 inputLength = _input.length;
        uint256 keysLength = inputLength > ADDRESS_LENGTH ? (inputLength - ADDRESS_LENGTH) / WORD_LENGTH : 0;
        if (
            anchorBlockHash == bytes32(0) ||
            stale ||
            keysLength == 0 ||
            keysLength > L1SLOAD_MAX_KEYS ||
            inputLength != ADDRESS_LENGTH + keysLength * WORD_LENGTH
        ) {
            assembly {
                invalid()
            }
        }

        address l1Contract = address(bytes20(_input[:ADDRESS_LENGTH]));
        output = new bytes(keysLength * WORD_LENGTH);
        for (uint256 i = 0; i < keysLength; ++i) {
            uint256 keyStart = ADDRESS_LENGTH + i * WORD_LENGTH;
            bytes32 value = l1StorageValue[l1Contract][bytes32(_input[keyStart:keyStart + WORD_LENGTH])];
            assembly {
                mstore(add(add(output, 0x20), mul(i, 0x20)), value)
            }
        }
    }
}
