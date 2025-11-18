// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {AlreadyWhitelisted, NotWhitelisted, ZeroAddress} from "../common/L1ContractErrors.sol";
import {ITransactionFilterer} from "../state-transition/chain-interfaces/ITransactionFilterer.sol";
import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {AssetRouterBase} from "../bridge/asset-router/AssetRouterBase.sol";
import {IL2SharedBridgeLegacyFunctions} from "../bridge/interfaces/IL2SharedBridgeLegacyFunctions.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Filters transactions received by the Mailbox
/// @dev Allows only deposits (from anyone), and arbitrary transactions from whitelisted senders.
contract PrividiumTransactionFilterer is ITransactionFilterer, Ownable2StepUpgradeable {
    /// @notice Event emitted when sender is whitelisted
    event WhitelistGranted(address indexed sender);

    /// @notice Event emitted when sender is removed from whitelist
    event WhitelistRevoked(address indexed sender);

    /// @notice The ecosystem's Bridgehub
    IBridgehubBase public immutable BRIDGE_HUB;

    /// @notice The L1 asset router
    address public immutable L1_ASSET_ROUTER;

    /// @notice Indicates whether the sender is whitelisted to deposit to Gateway
    mapping(address sender => bool whitelisted) public whitelistedSenders;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehubBase _bridgeHub, address _assetRouter) {
        BRIDGE_HUB = _bridgeHub;
        L1_ASSET_ROUTER = _assetRouter;
        _disableInitializers();
    }

    /// @notice Initializes a contract filterer for later use. Expected to be used in the proxy.
    /// @param _owner The address which can upgrade the implementation.
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_owner);
    }

    /// @notice Whitelists the sender.
    /// @param sender Address of the tx sender.
    function grantWhitelist(address sender) external onlyOwner {
        if (whitelistedSenders[sender]) {
            revert AlreadyWhitelisted(sender);
        }
        whitelistedSenders[sender] = true;
        emit WhitelistGranted(sender);
    }

    /// @notice Revoke the sender from whitelist.
    /// @param sender Address of the tx sender.
    function revokeWhitelist(address sender) external onlyOwner {
        if (!whitelistedSenders[sender]) {
            revert NotWhitelisted(sender);
        }
        whitelistedSenders[sender] = false;
        emit WhitelistRevoked(sender);
    }

    /// @notice Checks if the transaction is allowed
    /// @param sender The sender of the transaction
    /// @param l2Value The value sent with the L2 transaction
    /// @param l2Calldata The calldata of the L2 transaction
    /// @return Whether the transaction is allowed
    function isTransactionAllowed(
        address sender,
        address,
        uint256,
        uint256 l2Value,
        bytes calldata l2Calldata,
        address
    ) external view returns (bool) {
        // Only whitelisted senders are allowed to perform arbitrary transactions.
        if (whitelistedSenders[sender]) {
            return true;
        }

        if (sender == L1_ASSET_ROUTER) {
            // Non-base token deposit via `requestL2TransactionTwoBridges`
            bytes4 l2TxSelector = bytes4(l2Calldata[:4]);
            if (l2TxSelector == AssetRouterBase.finalizeDeposit.selector) {
                (, bytes32 assetId, bytes memory data) = abi.decode(l2Calldata[4:], (uint256, bytes32, bytes));
                // slither-disable-next-line unused-return
                (address depositor, , , uint256 amount, ) = DataEncoding.decodeBridgeMintData(data);
                return whitelistedSenders[depositor] || (_isNotChain(assetId) && amount > 0);
            } else {
                // Chains cannot be bridged using legacy interface, so just checking the selector is fine.
                // In case later we need to filter by token/amount/receiver, use DataEncoding.decodeBridgeMintData on l2Calldata[4:]
                return l2TxSelector == IL2SharedBridgeLegacyFunctions.finalizeDeposit.selector;
            }
        } else {
            // Base token deposit via `requestL2TransactionDirect`
            return l2Value > 0 && l2Calldata.length == 0;
        }
    }

    /// @return true if asset is NOT a chain (i.e. a token)
    function _isNotChain(bytes32 assetId) internal view returns (bool) {
        address ctmAddress = BRIDGE_HUB.ctmAssetIdToAddress(assetId);
        return ctmAddress == address(0);
    }
}
