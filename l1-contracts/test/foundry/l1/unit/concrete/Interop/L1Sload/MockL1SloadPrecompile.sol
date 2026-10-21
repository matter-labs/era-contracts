// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {L2_INTEROP_ROOT_STORAGE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L1SLOAD_ANCHOR_BLOCK_HASH_SLOT, L1SLOAD_MAX_KEYS} from "contracts/common/Config.sol";

/// @notice Stand-in for the ZKsync OS L1SLOAD precompile, etched at `L1SLOAD_PRECOMPILE_ADDRESS`. Foundry runs the
/// "L1" and "L2" contracts of a test in one EVM, so the mock serves each key straight from the L1 contract's
/// storage (`vm.load`): L2 reads observe exactly what real L1 calls wrote. Like the OS, it reverts while
/// `L2InteropRootStorage` holds no anchor and on malformed input. Unlike the OS, it reads the latest L1 state
/// rather than the state at the anchored block. See {protocol-docs/l1sload.md}.
contract MockL1SloadPrecompile {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant ADDRESS_LENGTH = 20;
    uint256 internal constant WORD_LENGTH = 32;

    fallback(bytes calldata _input) external returns (bytes memory output) {
        require(VM.load(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_BLOCK_HASH_SLOT) != bytes32(0), "no L1 anchor");
        require(_input.length > ADDRESS_LENGTH, "no keys");
        uint256 keysLength = (_input.length - ADDRESS_LENGTH) / WORD_LENGTH;
        require((_input.length - ADDRESS_LENGTH) % WORD_LENGTH == 0, "malformed keys");
        require(keysLength <= L1SLOAD_MAX_KEYS, "too many keys");

        address l1Contract = address(bytes20(_input[:ADDRESS_LENGTH]));
        output = new bytes(keysLength * WORD_LENGTH);
        for (uint256 i = 0; i < keysLength; ++i) {
            uint256 keyStart = ADDRESS_LENGTH + i * WORD_LENGTH;
            bytes32 value = VM.load(l1Contract, bytes32(_input[keyStart:keyStart + WORD_LENGTH]));
            assembly {
                mstore(add(add(output, 0x20), mul(i, 0x20)), value)
            }
        }
    }
}
