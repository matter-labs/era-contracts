// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {AlreadyWhitelisted, NotWhitelisted, ZeroAddress} from "../common/L1ContractErrors.sol";
import {ITransactionFilterer} from "../state-transition/chain-interfaces/ITransactionFilterer.sol";
import {IZkSyncHyperchain} from "../state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Filters transactions received by the Mailbox
/// @dev Only allows whitelisted senders to deposit to Gateway
contract GatewayTransactionFilterer is ITransactionFilterer, ReentrancyGuard, Ownable2StepUpgradeable {
    /// @dev Event emitted when sender is whitelisted
    event WhitelistGranted(address indexed sender);

    /// @dev Event emitted when sender is removed from whitelist
    event WhitelistRevoked(address indexed sender);

    /// @dev Indicates whether the sender is whitelisted to deposit to Gateway
    mapping(address sender => bool whitelisted) public whitelistedSenders;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor() reentrancyGuardInitializer {
        _disableInitializers();
    }

    /// @dev Initializes a contract filterer for later use. Expected to be used in the proxy.
    /// @param _owner The address which can upgrade the implementation.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        require(_owner != address(0), "TxFilterer: owner 0");
        _transferOwnership(_owner);
    }

    /// @dev Whitelist the sender.
    /// @param sender Address of the tx sender.
    function grantWhitelist(address sender) external onlyOwner {
        if (whitelistedSenders[sender]) {
            revert AlreadyWhitelisted(sender);
        }
        whitelistedSenders[sender] = true;
        emit WhitelistGranted(sender);
    }

    /// @dev Revoke the sender from whitelist.
    /// @param sender Address of the tx sender.
    function revokeWhitelist(address sender) external onlyOwner {
        if (!whitelistedSenders[sender]) {
            revert NotWhitelisted(sender);
        }
        whitelistedSenders[sender] = false;
        emit WhitelistRevoked(sender);
    }

    /// @notice Check if the transaction is allowed
    /// @param sender The sender of the transaction
    /// @param _contractL2 The L2 receiver address
    /// @param _mintValue The value of the L1 transaction
    /// @param _l2Value The msg.value of the L2 transaction
    /// @param _l2Calldata The calldata of the L2 transaction
    /// @param _refundRecipient The address to refund the excess value
    /// @return Whether the transaction is allowed
    function isTransactionAllowed(
        address sender,
        address _contractL2,
        uint256 _mintValue,
        uint256 _l2Value,
        bytes calldata _l2Calldata,
        address _refundRecipient
    ) external view returns (bool) {
        address baseTokenBridge = IZkSyncHyperchain(msg.sender).getBaseTokenBridge();
        address bridgeHub = IZkSyncHyperchain(msg.sender).getBridgehub();
        (bytes32 decodedAssetId, bytes memory decodedAssetData) = abi.decode(_l2Calldata[4:], (bytes32, bytes)); // Decode data first
        // Then take the asset id and call the BH
        address stmAddress = IBridgehub(bridgeHub).stmAssetIdToAddress(decodedAssetId);

        return (whitelistedSenders[sender] && (sender != baseTokenBridge || stmAddress != address(0)));
    }
}
