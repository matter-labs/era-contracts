// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {L1SLOAD_PRECOMPILE_ADDRESS} from "./L2ContractAddresses.sol";
import {L1SLOAD_MAX_KEYS} from "../Config.sol";
import {L1SloadFailed, L1SloadInvalidKeyCount} from "../L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Reads L1 storage at the chain's L1SLOAD anchor through the ZKsync OS precompile.
/// See {protocol-docs/l1sload.md#reading-l1-state}.
library L1Reads {
    /// @notice Reads up to `L1SLOAD_MAX_KEYS` storage slots of an L1 contract at the anchored L1 block.
    /// @param _l1Contract The L1 contract.
    /// @param _keys The storage slots.
    /// @return values The slots' values, in the order of `_keys`.
    function l1sload(address _l1Contract, bytes32[] memory _keys) internal view returns (bytes32[] memory values) {
        uint256 keysLength = _keys.length;
        if (keysLength == 0 || keysLength > L1SLOAD_MAX_KEYS) {
            revert L1SloadInvalidKeyCount(keysLength);
        }

        // The precompile has no ABI (input `address || key_1 || ... || key_k`, output `k` raw words), so it can
        // only be reached with a low-level call. A failure, e.g. no anchor yet or a stale one, is surfaced, never
        // handled.
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory returnData) = L1SLOAD_PRECOMPILE_ADDRESS.staticcall(
            abi.encodePacked(_l1Contract, _keys)
        );
        if (!success || returnData.length != keysLength * 32) {
            revert L1SloadFailed(_l1Contract);
        }

        values = new bytes32[](keysLength);
        for (uint256 i = 0; i < keysLength; ++i) {
            bytes32 value;
            assembly ("memory-safe") {
                value := mload(add(add(returnData, 0x20), mul(i, 0x20)))
            }
            values[i] = value;
        }
    }
}
