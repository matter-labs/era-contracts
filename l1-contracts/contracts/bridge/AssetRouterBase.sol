// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAssetRouterBase} from "./interfaces/IAssetRouterBase.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {IL2BridgeLegacy} from "./interfaces/IL2BridgeLegacy.sol";
import {IL1AssetHandler} from "./interfaces/IL1AssetHandler.sol";
import {IL1NativeTokenVault} from "./interfaces/IL1NativeTokenVault.sol";
import {INullifier} from "./interfaces/INullifier.sol";

import {TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDRESS} from "../common/L2ContractAddresses.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {L2_ASSET_ROUTER_ADDR} from "../common/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
abstract contract AssetRouterBase is IAssetRouterBase, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Maps asset ID to address of corresponding asset handler.
    /// @dev Tracks the address of Asset Handler contracts, where bridged funds are locked for each asset.
    /// @dev P.S. this liquidity was locked directly in SharedBridge before.
    mapping(bytes32 assetId => address assetHandlerAddress) public assetHandlerAddress;

    /// @dev Address of native token vault.
    IL1NativeTokenVault public nativeTokenVault;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        require(msg.sender == address(BRIDGE_HUB), "ShB not BH");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub) {
        BRIDGE_HUB = _bridgehub;
    }

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _nativeTokenVault The address of the native token vault.
    function setNativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external onlyOwner {
        require(address(nativeTokenVault) == address(0), "ShB: native token vault already set");
        require(address(_nativeTokenVault) != address(0), "ShB: native token vault 0");
        nativeTokenVault = _nativeTokenVault;
    }

    /// @notice Sets the asset handler address for a given asset ID.
    /// @dev No access control on the caller, as msg.sender is encoded in the assetId.
    /// @param _assetData In most cases this parameter is bytes32 encoded token address. However, it can include extra information used by custom asset handlers.
    /// @param _assetHandlerAddress The address of the asset handler, which will hold the token of interest.
    function setAssetHandlerAddress(bytes32 _assetData, address _assetHandlerAddress) external virtual {
        address sender = msg.sender == address(nativeTokenVault) ? L2_NATIVE_TOKEN_VAULT_ADDRESS : msg.sender;
        bytes32 assetId = keccak256(abi.encode(uint256(block.chainid), sender, _assetData));
        assetHandlerAddress[assetId] = _assetHandlerAddress;
        emit AssetHandlerRegistered(assetId, _assetHandlerAddress, _assetData, sender);
    }

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
    ) external payable virtual;

    /// @notice Initiates a deposit transaction within Bridgehub, used by `requestL2TransactionTwoBridges`.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _l2Value The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _data The calldata for the second bridge deposit.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _l2Value,
        bytes calldata _data
    ) external payable virtual returns (L2TransactionRequestTwoBridgesInner memory request);

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    /// @param _transferData The data that is passed to the asset handler contract.
    function bridgehubWithdraw(
        uint256 _chainId,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external virtual returns (L2TransactionRequestTwoBridgesInner memory request);

    /// @notice Encodes the message for l2ToL1log sent during withdraw initialization.
    /// @param _assetId The encoding of the asset on L2 which is withdrawn.
    /// @param _l1bridgeMintData The calldata used by l1 asset handler to unlock tokens for recipient.
    function _getWithdrawMessage(
        bytes32 _assetId,
        bytes memory _l1bridgeMintData
    ) internal pure returns (bytes memory) {
        // note we use the IL1ERC20Bridge.finalizeWithdrawal function selector to specify the selector for L1<>L2 messages,
        // and we use this interface so that when the switch happened the old messages could be processed
        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(IAssetRouterBase.finalizeWithdrawal.selector, _assetId, _l1bridgeMintData);
    }

    /// @notice Finalizes the deposit and mint funds.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _assetId The encoding of the asset on L2.
    /// @param _transferData The encoded data required for deposit (address _l1Sender, uint256 _amount, address _l2Receiver, bytes memory erc20Data, address originToken).
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes memory _transferData) external virtual {
        address assetHandler = assetHandlerAddress[_assetId];

        if (assetHandler != address(0)) {
            IL1AssetHandler(assetHandler).bridgeMint(_chainId, _assetId, _transferData);
        } else {
            IL1AssetHandler(address(nativeTokenVault)).bridgeMint(_chainId, _assetId, _transferData);
            assetHandlerAddress[_assetId] = address(nativeTokenVault);
        }

        emit DepositFinalizedAssetRouter(_chainId, _assetId, keccak256(_transferData));
    }

    /// @notice Finalize the withdrawal and release funds.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _assetId The bridged asset ID.
    /// @param _transferData The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    function finalizeWithdrawal(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external virtual override returns (address l1Receiver, uint256 amount) {
        address assetHandler = assetHandlerAddress[_assetId];

        if (assetHandler != address(0)) {
            IL1AssetHandler(assetHandler).bridgeMint(_chainId, _assetId, _transferData);
        } else {
            IL1AssetHandler(address(nativeTokenVault)).bridgeMint(_chainId, _assetId, _transferData); // Maybe it's better to receive amount and receiver here? transferData may have different encoding
            assetHandlerAddress[_assetId] = address(nativeTokenVault);
        }

        (amount, l1Receiver) = abi.decode(_transferData, (uint256, address));

        emit WithdrawalFinalizedAssetRouter(_chainId, l1Receiver, _assetId, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
