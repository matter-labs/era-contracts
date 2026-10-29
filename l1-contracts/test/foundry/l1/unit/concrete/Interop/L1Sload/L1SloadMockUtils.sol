// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {MockL1SloadPrecompile} from "contracts/dev-contracts/MockL1SloadPrecompile.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {L1_BLOCK_HASH_IMPORT_ID} from "contracts/common/Config.sol";
import {
    L1SLOAD_PRECOMPILE_ADDR,
    L2_BOOTLOADER_ADDRESS,
    L2_INTEROP_ROOT_STORAGE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Helpers for L2 code that reads L1 with L1SLOAD in a Foundry EVM, which has no such precompile: {install}
/// etches the real `L2InteropRootStorage` and {MockL1SloadPrecompile} at their addresses.
library L1SloadMockUtils {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function install() internal {
        VM.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);
        VM.etch(L1SLOAD_PRECOMPILE_ADDR, address(new MockL1SloadPrecompile()).code);
    }

    /// @dev The interop root the server imports for an L1 anchor.
    function anchorRoot(
        uint256 _blockNumber,
        bytes32 _blockHash,
        uint256 _timestamp
    ) internal pure returns (InteropRoot memory root) {
        root.chainId = L1_BLOCK_HASH_IMPORT_ID;
        root.blockOrBatchNumber = _blockNumber;
        root.timestamp = _timestamp;
        root.sides = new bytes32[](1);
        root.sides[0] = _blockHash;
    }

    /// @dev Imports an anchor the way the bootloader does.
    function importAnchor(uint256 _blockNumber, bytes32 _blockHash, uint256 _timestamp) internal {
        VM.prank(L2_BOOTLOADER_ADDRESS);
        L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR).addSingleInteropRoot(
            anchorRoot(_blockNumber, _blockHash, _timestamp)
        );
    }

    /// @dev Sets the value the mock serves for one storage slot of an L1 contract.
    function setL1Storage(address _l1Contract, bytes32 _key, bytes32 _value) internal {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = _key;
        bytes32[] memory values = new bytes32[](1);
        values[0] = _value;
        MockL1SloadPrecompile(L1SLOAD_PRECOMPILE_ADDR).setL1StorageValues(_l1Contract, keys, values);
    }
}
