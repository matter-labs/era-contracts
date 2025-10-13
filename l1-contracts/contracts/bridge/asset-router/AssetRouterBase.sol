// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {IAssetHandler} from "../interfaces/IAssetHandler.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

import {Unauthorized} from "../../common/L1ContractErrors.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
abstract contract AssetRouterBase is IAssetRouterBase, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Maps asset ID to address of corresponding asset handler.
    /// @dev Tracks the address of Asset Handler contracts, where bridged funds are locked for each asset.
    /// @dev P.S. this liquidity was locked directly in SharedBridge before.
    /// @dev Current AssetHandlers: NTV for tokens, Bridgehub for chains.
    mapping(bytes32 assetId => address assetHandlerAddress) public assetHandlerAddress;

    /// @dev Maps asset ID to the asset deployment tracker address.
    /// @dev Tracks the address of Deployment Tracker contract on L1, which sets Asset Handlers on L2s (ZK chain).
    /// @dev For the asset and stores respective addresses.
    /// @dev Current AssetDeploymentTrackers: NTV for tokens, CTMDeploymentTracker for chains.
    mapping(bytes32 assetId => address assetDeploymentTracker) public assetDeploymentTracker;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[48] private __gap;

    /// @notice Sets the asset handler address for a specified asset ID on the chain of the asset deployment tracker.
    /// @dev The caller of this function is encoded within the `assetId`, therefore, it should be invoked by the asset deployment tracker contract.
    /// @dev No access control on the caller, as msg.sender is encoded in the assetId.
    /// @dev Typically, for most tokens, ADT is the native token vault. However, custom tokens may have their own specific asset deployment trackers.
    /// @dev `setAssetHandlerAddressOnCounterpart` should be called on L1 to set asset handlers on L2 chains for a specific asset ID.
    /// @param _assetRegistrationData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetHandlerAddress The address of the asset handler to be set for the provided asset.
    function setAssetHandlerAddressThisChain(
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) external virtual;

    function _setAssetHandlerAddressThisChain(
        address _nativeTokenVault,
        bytes32 _assetRegistrationData,
        address _assetHandlerAddress
    ) internal {
        bool senderIsNTV = msg.sender == _nativeTokenVault;
        address sender = senderIsNTV ? L2_NATIVE_TOKEN_VAULT_ADDR : msg.sender;
        bytes32 assetId = DataEncoding.encodeAssetId(block.chainid, _assetRegistrationData, sender);
        if (!senderIsNTV && msg.sender != assetDeploymentTracker[assetId]) {
            revert Unauthorized(msg.sender);
        }
        _setAssetHandler(assetId, _assetHandlerAddress);
        assetDeploymentTracker[assetId] = msg.sender;
        emit AssetDeploymentTrackerRegistered(assetId, _assetRegistrationData, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            Receive transaction Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalize the withdrawal and release funds.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _assetId The bridged asset ID.
    /// @param _transferData The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @dev We have both the legacy finalizeWithdrawal and the new finalizeDeposit functions,
    /// finalizeDeposit uses the new format. On the L2 we have finalizeDeposit with new and old formats both.
    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) public payable virtual;

    function _finalizeDeposit(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData,
        address _nativeTokenVault
    ) internal {
        address assetHandler = assetHandlerAddress[_assetId];

        if (assetHandler != address(0)) {
            IAssetHandler(assetHandler).bridgeMint{value: msg.value}(_chainId, _assetId, _transferData);
        } else {
            _setAssetHandler(_assetId, _nativeTokenVault);
            // Native token vault may not support non-zero `msg.value`, but we still provide it here to
            // prevent the passed ETH from being stuck in the asset router and also for consistency.
            // So the decision on whether to support non-zero `msg.value` is done at the asset handler layer.
            IAssetHandler(_nativeTokenVault).bridgeMint{value: msg.value}(_chainId, _assetId, _transferData); // ToDo: Maybe it's better to receive amount and receiver here? transferData may have different encoding
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    function _setAssetHandler(bytes32 _assetId, address _assetHandlerAddress) internal {
        assetHandlerAddress[_assetId] = _assetHandlerAddress;
        emit AssetHandlerRegistered(_assetId, _assetHandlerAddress);
    }

    /// @dev send the burn message to the asset
    /// @notice Forwards the burn request for specific asset to respective asset handler.
    /// @param _chainId The chain ID of the ZK chain to which to deposit.
    /// @param _nextMsgValue The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _assetId The deposited asset ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @param _passValue Boolean indicating whether to pass msg.value in the call.
    /// @param _nativeTokenVault The address of the native token vault.
    /// @return bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    function _burn(
        uint256 _chainId,
        uint256 _nextMsgValue,
        bytes32 _assetId,
        address _originalCaller,
        bytes memory _transferData,
        bool _passValue,
        address _nativeTokenVault
    ) internal returns (bytes memory bridgeMintCalldata) {
        address l1AssetHandler = assetHandlerAddress[_assetId];
        if (l1AssetHandler == address(0)) {
            // As a UX feature, whenever an asset handler is not present, we always try to register asset within native token vault.
            // The Native Token Vault is trusted to revert in an asset does not belong to it.
            //
            // Note, that it may "pollute" error handling a bit: instead of getting error for asset handler not being
            // present, the user will get whatever error the native token vault will return, however, providing
            // more advanced error handling requires more extensive code and will be added in the future releases.
            INativeTokenVaultBase(_nativeTokenVault).tryRegisterTokenFromBurnData(_transferData, _assetId);

            // We do not do any additional transformations here (like setting `assetHandler` in the mapping),
            // because we expect that all those happened inside `tryRegisterTokenFromBurnData`

            l1AssetHandler = _nativeTokenVault;
        }

        uint256 msgValue = _passValue ? msg.value : 0;
        bridgeMintCalldata = IAssetHandler(l1AssetHandler).bridgeBurn{value: msgValue}({
            _chainId: _chainId,
            _msgValue: _nextMsgValue,
            _assetId: _assetId,
            _originalCaller: _originalCaller,
            _data: _transferData
        });
    }

    /// @notice Ensures that token is registered with native token vault.
    /// @dev Only used when deposit is made with legacy data encoding format.
    /// @param _token The native token address which should be registered with native token vault.
    /// @return assetId The asset ID of the token provided.
    function _ensureTokenRegisteredWithNTV(address _token) internal virtual returns (bytes32 assetId);

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
