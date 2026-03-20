// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2V31Upgrade {
    /// @notice Executes the one‑time upgrade.
    /// @dev Intended to be delegate‑called by the `ComplexUpgrader` contract.
    /// @param _baseTokenOriginChainId The chainId of the origin chain of the base token.
    /// @param _baseTokenOriginAddress The address of the base token on the origin chain.
    /// @param _baseTokenName The base token name.
    /// @param _baseTokenSymbol The base token symbol.
    /// @param _baseTokenDecimals The base token decimals.
    function upgrade(
        uint256 _baseTokenOriginChainId,
        address _baseTokenOriginAddress,
        string calldata _baseTokenName,
        string calldata _baseTokenSymbol,
        uint256 _baseTokenDecimals
    ) external;
}
