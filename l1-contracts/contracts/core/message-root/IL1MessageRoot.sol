// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IL1MessageRoot {
    /// @notice Governance enabled interop for the chain.
    event InteropEnabled(uint256 indexed chainId);

    function v31UpgradeChainBatchNumber(uint256 _chainId) external view returns (uint256);

    /// @notice Enables interop for a chain. One-way: there is no way to disable it. Callable by the
    /// Bridgehub owner. See {protocol-docs/interop-gating.md#enabling-interop}.
    /// @param _chainId The chain to enable interop for.
    /// @param _requireSecondProofSystem Whether the chain must permanently require its second proof system and be
    /// in multi-proof mode.
    function enableInterop(uint256 _chainId, bool _requireSecondProofSystem) external;

    /// @notice Returns whether governance enabled interop for the chain; false for unknown chains.
    /// See {protocol-docs/interop-gating.md}.
    /// @param _chainId The chain to query.
    function isInteropEnabled(uint256 _chainId) external view returns (bool);
}
