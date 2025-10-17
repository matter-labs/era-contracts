// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @dev The encoding version used for legacy txs.
bytes1 constant LEGACY_ENCODING_VERSION = 0x00;

/// @dev The encoding version used for new txs.
bytes1 constant NEW_ENCODING_VERSION = 0x01;

/// @dev The encoding version used for txs that set the asset handler on the counterpart contract.
bytes1 constant SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION = 0x02;

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IAssetRouterBase {
    event BridgehubDepositBaseTokenInitiated(
        uint256 indexed chainId,
        address indexed from,
        bytes32 assetId,
        uint256 amount
    );

    event BridgehubDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        address indexed from,
        bytes32 assetId,
        bytes bridgeMintCalldata
    );

    event BridgehubWithdrawalInitiated(
        uint256 chainId,
        address indexed sender,
        bytes32 indexed assetId,
        bytes32 assetDataHash // Todo: What's the point of emitting hash?
    );

    event AssetDeploymentTrackerRegistered(
        bytes32 indexed assetId,
        bytes32 indexed additionalData,
        address assetDeploymentTracker
    );

    event AssetHandlerRegistered(bytes32 indexed assetId, address indexed _assetHandlerAddress);

    event DepositFinalizedAssetRouter(uint256 indexed chainId, bytes32 indexed assetId, bytes assetData);

    function assetHandlerAddress(bytes32 _assetId) external view returns (address);


    /// @notice Generates a calldata for calling the deposit finalization on the L2 native token contract.
    /// @param _sender The address of the deposit initiator.
    /// @param _assetId The deposited asset ID.
    /// @param _assetData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @return Returns calldata used on ZK chain.
    function getDepositCalldata(
        address _sender,
        bytes32 _assetId,
        bytes memory _assetData
    ) external view returns (bytes memory);

    /// @notice Allows bridgehub to acquire mintValue for L1->L2 and L2->L2 transactions.
    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _assetId The deposited asset ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _amount The total amount of tokens to be bridged.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _originalCaller,
        uint256 _amount
    ) external payable;
}
