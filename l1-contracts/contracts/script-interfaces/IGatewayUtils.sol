// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {TxStatus} from "../../contracts/common/Messaging.sol";

/// @title IGatewayUtils
/// @notice Interface for GatewayUtils.s.sol script
/// @dev This interface ensures selector visibility for gateway utility functions
interface IGatewayUtils {
    function finishMigrateChainToGateway(
        address bridgehubAddr,
        bytes memory gatewayDiamondCutData,
        uint256 migratingChainId,
        uint256 gatewayChainId,
        bytes32 l2TxHash,
        uint256 l2BatchNumber,
        uint256 l2MessageIndex,
        uint16 l2TxNumberInBatch,
        bytes32[] calldata merkleProof,
        TxStatus txStatus
    ) external;

    function finishMigrateChainFromGateway(
        address bridgehubAddr,
        uint256 migratingChainId,
        uint256 gatewayChainId,
        uint256 l2BatchNumber,
        uint256 l2MessageIndex,
        uint16 l2TxNumberInBatch,
        bytes memory message,
        bytes32[] memory merkleProof
    ) external;
}
