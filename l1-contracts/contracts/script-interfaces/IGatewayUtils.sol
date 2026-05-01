// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {TxStatus} from "../../contracts/common/Messaging.sol";

/// @notice Inputs for `finishMigrateChainToGateway`. Bundled into a struct to
/// keep the public ABI within the Yul-codegen stack budget when compiled
/// without the optimizer / viaIR (e.g. under `forge coverage`).
struct FinishMigrateChainToGatewayParams {
    address bridgehubAddr;
    uint256 migratingChainId;
    uint256 gatewayChainId;
    string gatewayRpcUrl;
    bytes32 l2TxHash;
    uint256 l2BatchNumber;
    uint256 l2MessageIndex;
    uint16 l2TxNumberInBatch;
    bytes32[] merkleProof;
    TxStatus txStatus;
}

/// @title IGatewayUtils
/// @notice Interface for GatewayUtils.s.sol script
/// @dev This interface ensures selector visibility for gateway utility functions
interface IGatewayUtils {
    function finishMigrateChainToGateway(FinishMigrateChainToGatewayParams calldata params) external;

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

    function dumpForceDeployments(address _ctm) external;
}
