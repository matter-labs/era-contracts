// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2MessageVerification} from "contracts/interop/L2MessageVerification.sol";
import {DummyL2InteropRootStorage} from "contracts/dev-contracts/test/DummyL2InteropRootStorage.sol";
import {
    L2_INTEROP_ROOT_STORAGE_ADDR,
    L2_MESSAGE_VERIFICATION_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Stands up the REAL cross-chain message-verification stack at its system-contract addresses so
/// tests can drive `proveL2MessageInclusionShared` for real, and seeds the imported interop roots proofs
/// resolve against.
/// @dev The verifier is a plain re-parsing/Merkle contract with no constructor state, and the interop-root
/// storage is a mapping, so `vm.etch` (code-only, no constructor) is sufficient — the same pattern the
/// broader L2-in-L1 harness ({L2UtilsBase}) uses for these two contracts. Roots are populated through the
/// storage's real `addInteropRoot` entry point, not by writing storage slots directly.
abstract contract InteropVerificationFixture is Test {
    /// @dev Etches the real verifier + interop-root storage at their canonical addresses.
    function _deployMessageVerification() internal {
        vm.etch(L2_MESSAGE_VERIFICATION_ADDR, address(new L2MessageVerification()).code);
        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new DummyL2InteropRootStorage()).code);
    }

    /// @dev Anchors `_root` as the settlement layer's imported interop root at `(_slChainId, _slBlock)`.
    /// A message-inclusion proof resolving to `_root` verifies; any other resolved value does not.
    function _seedInteropRoot(uint256 _slChainId, uint256 _slBlock, bytes32 _root) internal {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = _root;
        DummyL2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR).addInteropRoot(_slChainId, _slBlock, sides);
    }
}
