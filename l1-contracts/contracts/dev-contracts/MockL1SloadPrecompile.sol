// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL2InteropRootStorage} from "../interop/IL2InteropRootStorage.sol";
import {L2_INTEROP_ROOT_STORAGE_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @title MockL1SloadPrecompile
/// @notice Stand-in for the ZKsync OS L1SLOAD precompile (`L1SLOAD_PRECOMPILE_ADDRESS`, RIP-7728) on EVMs that don't
/// have it: the Foundry suites that run L2 contracts in one EVM, and the anvil-interop L2s. It parses the RIP-7728
/// input `address (20 bytes) || key_1 || ... || key_k (32 bytes each)` and answers `value_1 || ... || value_k`.
/// See {protocol-docs/l1sload.md#reading-l1-state}.
/// @dev The values are whatever the harness last set with {setL1StorageValues}, read from the L1 contract (on anvil,
/// `eth_getStorageAt` on the L1) or chosen by the test; the precompile reads the L1 state at the anchored block.
/// Like the precompile, it reverts while `L2InteropRootStorage` holds no anchor, and fails consuming all gas on
/// input with no key, more than `MAX_KEYS` keys or a partial key.
contract MockL1SloadPrecompile {
    uint256 internal constant ADDRESS_LENGTH = 20;
    uint256 internal constant WORD_LENGTH = 32;
    /// @dev `L1SLOAD_MAX_KEYS`; repeated so the anvil build of this file does not depend on `Config.sol`.
    uint256 internal constant MAX_KEYS = 5;

    /// @notice The value served for `_key` of `_l1Contract`.
    mapping(address l1Contract => mapping(bytes32 key => bytes32 value)) public l1StorageValue;

    /// @notice Sets the values served for storage slots of an L1 contract.
    /// @param _l1Contract The L1 contract.
    /// @param _keys The storage slots.
    /// @param _values The values, in the order of `_keys`.
    function setL1StorageValues(address _l1Contract, bytes32[] calldata _keys, bytes32[] calldata _values) external {
        uint256 keysLength = _keys.length;
        if (keysLength != _values.length) {
            assembly {
                revert(0, 0)
            }
        }
        for (uint256 i = 0; i < keysLength; ++i) {
            l1StorageValue[_l1Contract][_keys[i]] = _values[i];
        }
    }

    fallback(bytes calldata _input) external returns (bytes memory output) {
        if (IL2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR).l1AnchorBlockHash() == bytes32(0)) {
            assembly {
                revert(0, 0)
            }
        }
        uint256 inputLength = _input.length;
        uint256 keysLength = inputLength > ADDRESS_LENGTH ? (inputLength - ADDRESS_LENGTH) / WORD_LENGTH : 0;
        if (keysLength == 0 || keysLength > MAX_KEYS || inputLength != ADDRESS_LENGTH + keysLength * WORD_LENGTH) {
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
