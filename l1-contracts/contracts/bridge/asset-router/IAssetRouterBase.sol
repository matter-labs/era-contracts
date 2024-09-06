// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IBridgehub, L2TransactionRequestTwoBridgesInner} from "../../bridgehub/IBridgehub.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";

/// @dev The encoding version used for new txs.
bytes1 constant LEGACY_ENCODING_VERSION = 0x00;

/// @dev The encoding version used for legacy txs.
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

    // event DepositFinalizedAssetRouter(uint256 chainId, address receiver, bytes32 indexed assetId, uint256 amount); // why hash? shall we make it similar to WithdrawalFinalizedAssetRouter?

    event AssetHandlerRegisteredInitial(
        bytes32 indexed assetId,
        address indexed assetHandlerAddress,
        bytes32 indexed additionalData,
        address assetDeploymentTracker
    );

    event AssetHandlerRegistered(bytes32 indexed assetId, address indexed _assetAddress);

    function BRIDGE_HUB() external view returns (IBridgehub);
    function BASE_TOKEN_ADDRESS() external view returns (address);

    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _assetId The deposited asset ID.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _amount The total amount of tokens to be bridged.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        uint256 _amount
    ) external payable;

    /// @notice Initiates a transfer transaction within Bridgehub, used by `requestL2TransactionTwoBridges`.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _value The `msg.value` on the target chain tx.
    /// @param _data The calldata for the second bridge deposit.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    /// @dev Data has the following abi encoding for legacy deposits:
    /// address _l1Token,
    /// uint256 _amount,
    /// address _l2Receiver
    /// for new deposits:
    /// bytes32 _assetId,
    /// bytes _transferData
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (L2TransactionRequestTwoBridgesInner memory request);

    function bridgehubConfirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;

    function setAssetHandlerAddressThisChain(bytes32 _additionalData, address _assetHandlerAddress) external;

    function assetHandlerAddress(bytes32 _assetId) external view returns (address);

    function nativeTokenVault() external view returns (INativeTokenVault);

    /// @notice Generates a calldata for calling the deposit finalization on the L2 native token contract.
    // / @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _sender The address of the deposit initiator.
    /// @param _assetId The deposited asset ID.
    /// @param _assetData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @return Returns calldata used on ZK chain.
    function getDepositCalldata(
        address _sender,
        bytes32 _assetId,
        bytes memory _assetData
    ) external view returns (bytes memory);

    /// @dev Used to set the assedAddress for a given assetId.
    /// @dev Will be used by ZK Gateway
    function setAssetHandlerAddress(uint256 _originChainId, bytes32 _assetId, address _assetAddress) external;
}
