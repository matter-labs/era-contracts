// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title IGatewayUtils
/// @notice Interface for GatewayUtils.s.sol script
/// @dev This interface ensures selector visibility for gateway utility functions
interface IGatewayUtils {
    function finishMigrateChainFromGateway(
        address bridgehubAddr,
        uint256 gatewayChainId,
        uint256 l2BatchNumber,
        uint256 l2MessageIndex,
        uint16 l2TxNumberInBatch,
        bytes memory message,
        bytes32[] memory merkleProof
    ) external;
}
