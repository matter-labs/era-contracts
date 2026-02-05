// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IBridgehubBase, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "./IBridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Interface for L1-specific Bridgehub functionality
interface IL1Bridgehub is IBridgehubBase {
    /// @notice Get L1 chain ID
    function L1_CHAIN_ID() external view returns (uint256);
    /// @notice Request L2 transaction directly
    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    /// @notice Request L2 transaction through two bridges
    function requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    /// @notice Create new chain
    function createNewChain(
        uint256 _chainId,
        address _chainTypeManager,
        bytes32 _baseTokenAssetId,
        uint256 _salt,
        address _admin,
        bytes calldata _initData,
        bytes[] calldata _factoryDeps
    ) external returns (uint256 chainId);

    /// @notice Set settlement layer status
    function setSettlementLayerStatus(uint256 _settlementLayerChainId, bool _isWhitelisted) external;

    /// @notice Set addresses (L1 specific)
    // function setAddresses(
    //     address _assetRouter,
    //     ICTMDeploymentTracker _l1CtmDeployer,
    //     IMessageRoot _messageRoot,
    //     address _chainAssetHandler,
    //     address _chainRegistrationSender
    // ) external;

    /// @notice Register already deployed ZK chain
    function registerAlreadyDeployedZKChain(uint256 _chainId, address _hyperchain) external;
}
