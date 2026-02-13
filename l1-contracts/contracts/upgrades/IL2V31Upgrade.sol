// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2V31Upgrade {
    /// @notice Executes the one‑time upgrade.
    /// @dev Intended to be delegate‑called by the `ComplexUpgrader` contract.
    /// @param _baseTokenOriginChainId The chainId of the origin chain of the base token.
    /// @param _baseTokenOriginAddress The address of the base token on the origin chain.
    function upgrade(uint256 _baseTokenOriginChainId, address _baseTokenOriginAddress) external;

    function setZkosPreV31TotalSupply(uint256 _totalSupply) external;
}
