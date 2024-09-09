// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {AlreadyWhitelisted, InvalidSelector, NotWhitelisted, ZeroAddress} from "../common/L1ContractErrors.sol";
import {ITransactionFilterer} from "../state-transition/chain-interfaces/ITransactionFilterer.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {IL2Bridge} from "../bridge/interfaces/IL2Bridge.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Filters transactions received by the Mailbox
/// @dev Only allows whitelisted senders to deposit to Gateway
contract GatewayTransactionFilterer is ITransactionFilterer, ReentrancyGuard, Ownable2StepUpgradeable {
    /// @dev Event emitted when sender is whitelisted
    event WhitelistGranted(address indexed sender);

    /// @dev Event emitted when sender is removed from whitelist
    event WhitelistRevoked(address indexed sender);

    /// @dev Bridgehub is set during construction
    IBridgehub public immutable bridgeHub;

    /// @dev Asset router is set during construction
    address public immutable assetRouter;

    /// @dev Indicates whether the sender is whitelisted to deposit to Gateway
    mapping(address sender => bool whitelisted) public whitelistedSenders;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgeHub, address _assetRouter) reentrancyGuardInitializer {
        bridgeHub = _bridgeHub;
        assetRouter = _assetRouter;
        _disableInitializers();
    }

    /// @dev Initializes a contract filterer for later use. Expected to be used in the proxy.
    /// @param _owner The address which can upgrade the implementation.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
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
    /// @param l2Calldata The calldata of the L2 transaction
    /// @return Whether the transaction is allowed
    function isTransactionAllowed(
        address sender,
        address,
        uint256,
        uint256,
        bytes calldata l2Calldata,
        address
    ) external view returns (bool) {
        if (sender == assetRouter) {
            bytes4 l2TxSelector = bytes4(l2Calldata[:4]);
            if (IL2Bridge.finalizeDeposit.selector != l2TxSelector) {
                revert InvalidSelector(l2TxSelector);
            }

            (bytes32 decodedAssetId, ) = abi.decode(l2Calldata[4:], (bytes32, bytes));
            address stmAddress = bridgeHub.ctmAssetIdToAddress(decodedAssetId);
            return (stmAddress != address(0));
        }

        return whitelistedSenders[sender];
    }
}
