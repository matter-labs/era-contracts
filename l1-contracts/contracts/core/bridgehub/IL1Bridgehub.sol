// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IBridgehubBase, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "./IBridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Interface for L1-specific Bridgehub functionality
interface IL1Bridgehub is IBridgehubBase {
    /// @notice Emitted when the interop center allowed to forward requests is set.
    event InteropCenterSet(address indexed interopCenter);

    /// @notice Get L1 chain ID
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice The interop center allowed to request L1->L2 transactions on behalf of its own callers.
    function interopCenter() external view returns (address);

    /// @notice Sets the interop center allowed to forward requests.
    /// @param _interopCenter the address of the interop center
    function setInteropCenter(address _interopCenter) external;
    /// @notice Request L2 transaction directly
    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    /// @notice Request L2 transaction through two bridges
    function requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    /// @notice Request L2 transaction directly on behalf of `_originalCaller`.
    /// @dev Callable only by the interop center, which passes its own caller. The original caller provides the
    /// base token and becomes the sender of the L1->L2 transaction, so the request is indistinguishable from
    /// one they made themselves. See {protocol-docs/l1-interop-center.md#trusted-forwarding}.
    function requestL2TransactionDirectFor(
        address _originalCaller,
        L2TransactionRequestDirect calldata _request
    ) external payable returns (bytes32 canonicalTxHash);

    /// @notice Request L2 transaction through two bridges on behalf of `_originalCaller`.
    /// @dev Callable only by the interop center, which passes its own caller. The original caller provides the
    /// base token and is passed to the second bridge as the depositor, so the deposit stays recoverable by them.
    /// See {protocol-docs/l1-interop-center.md#trusted-forwarding}.
    function requestL2TransactionTwoBridgesFor(
        address _originalCaller,
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
    function registerAlreadyDeployedZKChain(uint256 _chainId, address _zkChain) external;
}
