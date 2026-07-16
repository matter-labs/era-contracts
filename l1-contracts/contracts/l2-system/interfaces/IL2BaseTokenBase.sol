// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @title IL2BaseTokenBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Base interface for L2 Base Token contracts (shared between Era and ZK OS).
/// @dev Base-token L2->L1 withdrawals are initiated through the InteropCenter (`sendBundle`), the same
/// unified path as ERC20 withdrawals; there is no dedicated `withdraw` entrypoint on the base token.
interface IL2BaseTokenBase {
    /// @notice Returns the total circulating supply of base tokens.
    function totalSupply() external view returns (uint256);

    /// @notice Initializes the L2 Base Token contract during genesis or V31 upgrade.
    /// @dev Sets the L1 chain ID and initializes the BaseTokenHolder balance.
    /// @dev The implementation varies between Era and ZK OS but both require this initialization.
    /// @param _l1ChainId The chain ID of L1.
    function initL2(uint256 _l1ChainId) external;
}
