// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IBridgehubBase, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "./IBridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Interface for L1-specific Bridgehub functionality
interface IL1Bridgehub is IBridgehubBase {
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

    /// @notice Register settlement layer
    function registerSettlementLayer(uint256 _newSettlementLayerChainId, bool _isWhitelisted) external;

    /// @notice Register already deployed ZK chain
    function registerAlreadyDeployedZKChain(uint256 _chainId, address _hyperchain) external;

    /// @notice Register legacy chain
    function registerLegacyChain(uint256 _chainId) external;
}
