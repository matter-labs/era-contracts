// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {L1View} from "contracts/common/l2-helpers/L1View.sol";
import {L1SLOAD_ANCHOR_BLOCK_HASH_SLOT, L1SLOAD_ANCHOR_BLOCK_NUMBER_SLOT} from "contracts/common/Config.sol";
import {
    L1SLOAD_PRECOMPILE_ADDRESS,
    L2_INTEROP_ROOT_STORAGE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {MockL1SloadPrecompile} from "./MockL1SloadPrecompile.sol";

/// @notice Stands up the L1 state that L2 contracts read with L1SLOAD for suites that run L2 contracts without the L1
/// contracts: {MockL1SloadPrecompile} at the precompile address, an anchor in `L2InteropRootStorage`, and the
/// `ChainRegistrationSender` gating state written straight into the slots `L1View` reads. `L1ViewStorageLayout.t.sol`
/// pins those slots against the real `ChainRegistrationSender`, and the suites in this folder write the state through
/// its real entry points. See {protocol-docs/l1sload.md}.
library L1SloadTestUtils {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 internal constant TRUE_WORD = bytes32(uint256(1));

    /// @dev Etches the mock precompile and imports an anchor, so L1 reads stop reverting.
    function enableL1Reads() internal {
        VM.etch(L1SLOAD_PRECOMPILE_ADDRESS, type(MockL1SloadPrecompile).runtimeCode);
        VM.store(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_BLOCK_HASH_SLOT, keccak256("l1sload test anchor"));
        VM.store(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_BLOCK_NUMBER_SLOT, bytes32(uint256(1)));
    }

    /// @dev `ChainRegistrationSender.allowInteropPeer(_chainId, _peerChainId)`: the allowance and the peer's base
    /// token snapshot.
    function allowInteropPeer(
        address _chainRegistrationSender,
        uint256 _chainId,
        uint256 _peerChainId,
        bytes32 _peerBaseTokenAssetId
    ) internal {
        VM.store(_chainRegistrationSender, L1View.interopPeerAllowedSlot(_chainId, _peerChainId), TRUE_WORD);
        VM.store(_chainRegistrationSender, L1View.interopBaseTokenAssetIdSlot(_peerChainId), _peerBaseTokenAssetId);
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

    /// @dev `ChainRegistrationSender.deregisterInteropPairs(_chainId, [_peerChainId])`.
    function deregisterInteropPeer(address _chainRegistrationSender, uint256 _chainId, uint256 _peerChainId) internal {
        VM.store(_chainRegistrationSender, L1View.interopPeerAllowedSlot(_chainId, _peerChainId), bytes32(0));
    }

    /// @dev Sets only the base token snapshot, as left by an allowance another chain made.
    function setInteropBaseTokenAssetId(
        address _chainRegistrationSender,
        uint256 _chainId,
        bytes32 _baseTokenAssetId
    ) internal {
        VM.store(_chainRegistrationSender, L1View.interopBaseTokenAssetIdSlot(_chainId), _baseTokenAssetId);
    }
}
