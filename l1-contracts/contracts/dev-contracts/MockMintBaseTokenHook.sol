// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockMintBaseTokenHook
/// @notice Mock for the ZK-VM MINT_BASE_TOKEN_HOOK (address 0x7100).
/// @dev In production, calling this hook mints ETH to the caller's address.
/// On Anvil, the caller must be pre-funded via anvil_setBalance before calling this.
/// This mock simply returns success without doing anything.
contract MockMintBaseTokenHook {
    fallback() external payable {
        // No-op: Anvil pre-funds the caller via anvil_setBalance
    }

    receive() external payable {}
}
