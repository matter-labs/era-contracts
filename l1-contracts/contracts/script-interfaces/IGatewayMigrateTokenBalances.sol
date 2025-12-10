// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title IGatewayMigrateTokenBalances
/// @notice Interface for GatewayMigrateTokenBalances.s.sol script
interface IGatewayMigrateTokenBalances {
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

    function checkAllMigrated(uint256 chainId, string memory l2RpcUrl) external;
}
