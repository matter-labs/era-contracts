// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IGatewayMigrateTokenBalances {
    /// @notice Returns the bridged token asset IDs on L2.
    /// @return bridgedTokenCountPlusOne The number of bridged tokens plus one (for the base asset).
    /// @return assetIds The list of asset IDs.
    function getBridgedTokenAssetIds() external returns (uint256 bridgedTokenCountPlusOne, bytes32[] memory assetIds);

    /// @notice Finalizes token balance migration on L1 by finalizing deposits and calling receiveMigrationOnL1.
    /// @param toGateway Whether the migration is to the gateway.
    /// @param bridgehub The Bridgehub contract interface.
    /// @param chainId The chain ID being migrated.
    /// @param gatewayChainId The gateway's chain ID.
    /// @param l2RpcUrl The L2 RPC URL.
    /// @param gwRpcUrl The gateway RPC URL.
    /// @param onlyWaitForFinalization Whether to only wait for finalization, but not call receiveMigrationOnL1.
    /// @param txHashes The L2 transaction hashes.
    function finishMigrationOnL1(
        bool toGateway,
        address bridgehub,
        uint256 chainId,
        uint256 gatewayChainId,
        string memory l2RpcUrl,
        string memory gwRpcUrl,
        bool onlyWaitForFinalization,
        bytes32[] memory txHashes
    ) external;

    /// @notice Checks that all tokens have been migrated for a given chainId.
    /// @param chainId The chain ID.
    /// @param l2RpcUrl The L2 RPC URL.
    function checkAllMigrated(uint256 chainId, string memory l2RpcUrl) external;
}
