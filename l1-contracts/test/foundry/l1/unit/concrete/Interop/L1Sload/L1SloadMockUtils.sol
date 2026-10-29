// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {MockL1SloadPrecompile} from "contracts/dev-contracts/MockL1SloadPrecompile.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {L1View} from "contracts/common/l2-helpers/L1View.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {L1_BLOCK_HASH_IMPORT_ID} from "contracts/common/Config.sol";
import {
    L1SLOAD_PRECOMPILE_ADDRESS,
    L2_BOOTLOADER_ADDRESS,
    L2_INTEROP_ROOT_STORAGE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Helpers for L2 contracts that read L1 with L1SLOAD in a single Foundry EVM, which has no such precompile:
/// {installMock} etches {MockL1SloadPrecompile} at its address, and the helpers set what it serves.
library L1SloadMockUtils {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 internal constant TRUE_WORD = bytes32(uint256(1));

    function mock() internal pure returns (MockL1SloadPrecompile) {
        return MockL1SloadPrecompile(L1SLOAD_PRECOMPILE_ADDRESS);
    }

    function installMock() internal {
        VM.etch(L1SLOAD_PRECOMPILE_ADDRESS, address(new MockL1SloadPrecompile()).code);
    }

    /// @dev The L1 block-hash anchor entry the server imports.
    function anchorRoot(
        uint256 _blockNumber,
        bytes32 _blockHash,
        uint256 _timestamp
    ) internal pure returns (InteropRoot memory anchor) {
        anchor.chainId = L1_BLOCK_HASH_IMPORT_ID;
        anchor.blockOrBatchNumber = _blockNumber;
        anchor.timestamp = _timestamp;
        anchor.sides = new bytes32[](1);
        anchor.sides[0] = _blockHash;
    }

    /// @dev Imports an anchor the way the bootloader does.
    function importAnchor(uint256 _blockNumber, bytes32 _blockHash, uint256 _timestamp) internal {
        VM.prank(L2_BOOTLOADER_ADDRESS);
        L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR).addSingleInteropRoot(
            anchorRoot(_blockNumber, _blockHash, _timestamp)
        );
    }

    function setL1Storage(address _l1Contract, bytes32[] memory _keys, bytes32[] memory _values) internal {
        mock().setL1StorageValues(_l1Contract, _keys, _values);
    }

    function setL1Storage(address _l1Contract, bytes32 _key, bytes32 _value) internal {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = _key;
        bytes32[] memory values = new bytes32[](1);
        values[0] = _value;
        setL1Storage(_l1Contract, keys, values);
    }

    /// @dev Serves the given slots of an L1 contract in the same EVM with their current values.
    function syncFromL1(address _l1Contract, bytes32[] memory _keys) internal {
        bytes32[] memory values = new bytes32[](_keys.length);
        for (uint256 i = 0; i < _keys.length; ++i) {
            values[i] = VM.load(_l1Contract, _keys[i]);
        }
        setL1Storage(_l1Contract, _keys, values);
    }

    /// @dev What `ChainRegistrationSender.allowInteropPeer(_chainId, _peerChainId)` leaves on L1.
    function allowInteropPeer(
        address _chainRegistrationSender,
        uint256 _chainId,
        uint256 _peerChainId,
        bytes32 _peerBaseTokenAssetId
    ) internal {
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = L1View.interopPeerAllowedSlot(_chainId, _peerChainId);
        keys[1] = L1View.interopBaseTokenAssetIdSlot(_peerChainId);
        bytes32[] memory values = new bytes32[](2);
        values[0] = TRUE_WORD;
        values[1] = _peerBaseTokenAssetId;
        setL1Storage(_chainRegistrationSender, keys, values);
    }

    /// @dev Both admins allow each other.
    function allowInteropPair(
        address _chainRegistrationSender,
        uint256 _chainId,
        bytes32 _baseTokenAssetId,
        uint256 _peerChainId,
        bytes32 _peerBaseTokenAssetId
    ) internal {
        allowInteropPeer(_chainRegistrationSender, _chainId, _peerChainId, _peerBaseTokenAssetId);
        allowInteropPeer(_chainRegistrationSender, _peerChainId, _chainId, _baseTokenAssetId);
    }

    /// @dev What `ChainRegistrationSender.deregisterInteropPairs(_chainId, [_peerChainId])` leaves on L1.
    function deregisterInteropPeer(address _chainRegistrationSender, uint256 _chainId, uint256 _peerChainId) internal {
        setL1Storage(_chainRegistrationSender, L1View.interopPeerAllowedSlot(_chainId, _peerChainId), bytes32(0));
    }

    /// @dev Only the base token snapshot, as an allowance by another chain leaves it.
    function setInteropBaseTokenAssetId(
        address _chainRegistrationSender,
        uint256 _chainId,
        bytes32 _baseTokenAssetId
    ) internal {
        setL1Storage(_chainRegistrationSender, L1View.interopBaseTokenAssetIdSlot(_chainId), _baseTokenAssetId);
    }
}
