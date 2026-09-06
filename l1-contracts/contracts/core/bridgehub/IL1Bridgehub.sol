// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IBridgehubBase} from "./IBridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Interface for L1-specific Bridgehub functionality
interface IL1Bridgehub is IBridgehubBase {
    /// @notice Sets the authorized L1 Interop Center; owner or protocol upgrader only.
    /// @param _interopCenter The new L1 Interop Center.
    function setInteropCenter(address _interopCenter) external;

    /// @notice Get L1 chain ID
    function L1_CHAIN_ID() external view returns (uint256);

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
    function registerAlreadyDeployedZKChain(uint256 _chainId, address _zkChain) external;
}
