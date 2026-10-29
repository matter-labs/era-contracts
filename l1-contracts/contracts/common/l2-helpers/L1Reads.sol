// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {L1SLOAD_PRECOMPILE_ADDR} from "./L2ContractAddresses.sol";
import {L2_INTEROP_ROOT_STORAGE} from "./L2ContractInterfaces.sol";
import {L1SLOAD_CALL_GAS, L1SLOAD_MAX_KEYS} from "../Config.sol";
import {L1AnchorStale, L1SloadFailed, L1SloadInvalidKeyCount} from "../L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Reads L1 storage at the chain's anchor through the ZKsync OS L1SLOAD precompile.
/// See {protocol-docs/l1sload.md}.
library L1Reads {
    /// @notice Returns the anchor the precompile reads at; all zero before the first anchor import.
    /// @return blockNumber The L1 block number.
    /// @return blockHash Its hash.
    /// @return timestamp The L1 time it was recorded at.
    function anchor() internal view returns (uint256 blockNumber, bytes32 blockHash, uint256 timestamp) {
        return L2_INTEROP_ROOT_STORAGE.l1Anchor();
    }

    /// @notice Reverts unless there is an anchor recorded at most `_maxAge` before this block.
    /// See {protocol-docs/l1sload.md#freshness}.
    /// @param _maxAge The maximum age, in L2 block time.
    function requireFresh(uint256 _maxAge) internal view {
        (, , uint256 timestamp) = anchor();
        if (timestamp == 0 || (block.timestamp > timestamp && block.timestamp - timestamp > _maxAge)) {
            revert L1AnchorStale(timestamp, block.timestamp);
        }
    }

    /// @notice Reads one storage slot of an L1 contract at the anchor.
    /// @param _l1Contract The L1 contract.
    /// @param _key The storage slot.
    /// @return The slot's value.
    function read(address _l1Contract, bytes32 _key) internal view returns (bytes32) {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = _key;
        return read(_l1Contract, keys)[0];
    }

    /// @notice Reads up to `L1SLOAD_MAX_KEYS` storage slots of an L1 contract at the anchor.
    /// @param _l1Contract The L1 contract.
    /// @param _keys The storage slots.
    /// @return values The slots' values, in the order of `_keys`.
    function read(address _l1Contract, bytes32[] memory _keys) internal view returns (bytes32[] memory values) {
        uint256 keysLength = _keys.length;
        if (keysLength == 0 || keysLength > L1SLOAD_MAX_KEYS) {
            revert L1SloadInvalidKeyCount(keysLength);
        }

        // A low-level call because the precompile has no ABI: its input is `l1Contract || key_1 || ... || key_k`
        // and its output the `k` raw values.
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory returnData) = L1SLOAD_PRECOMPILE_ADDR.staticcall{gas: L1SLOAD_CALL_GAS}(
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

    /// @notice Returns the storage slot of `mapping[_key]` for a mapping declared at `_slot`.
    /// @param _slot The mapping's slot.
    /// @param _key The key.
    function mappingSlot(bytes32 _slot, bytes32 _key) internal pure returns (bytes32) {
        return keccak256(abi.encode(_key, _slot));
    }
}
