// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {AlreadyWhitelisted, InvalidSelector, NotWhitelisted, ZeroAddress} from "../common/L1ContractErrors.sol";
import {L2_ASSET_ROUTER_ADDR} from "../common/L2ContractAddresses.sol";
import {ITransactionFilterer} from "../state-transition/chain-interfaces/ITransactionFilterer.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {IAssetRouterBase} from "../bridge/asset-router/IAssetRouterBase.sol";
import {IL2AssetRouter} from "../bridge/asset-router/IL2AssetRouter.sol";

/// @dev The errors below are written here instead of a dedicate file to avoid
/// source code changes to another contracts.y
// 0x55ccf3e4
error NotBlocklisted(address);
// 0x7b0b7f4f
error AlreadyBlocklisted(address);

/// @dev We want to ensure that only whitelisted contracts can ever be deployed,
/// while allowing anyone to call any other method. Thus, we disallow calls that can deploy contracts
/// (i.e. calls to the predeployed Create2Factory or ContractDeployer).
address constant MIN_ALLOWED_ADDRESS = address(0x20000);

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Filters transactions received by the Mailbox
/// @dev Only allows whitelisted senders to deposit to Gateway
contract GatewayTransactionFilterer is ITransactionFilterer, Ownable2StepUpgradeable {
    /// @notice Event emitted when sender is whitelisted
    event WhitelistGranted(address indexed sender);

    /// @notice Event emitted when sender is removed from whitelist
    event WhitelistRevoked(address indexed sender);

    /// @notice Event emitted when contract is blocklisted
    event Blocklisted(address indexed l2Contract);

    /// @notice Event emitted when contract is removed from blocklist
    event RemovedFromBlocklist(address indexed l2Contract);

    /// @notice The ecosystem's Bridgehub
    IBridgehub public immutable BRIDGE_HUB;

    /// @notice The L1 asset router
    address public immutable L1_ASSET_ROUTER;

    /// @notice Indicates whether the sender is allowed to call any contract on Gateway
    mapping(address sender => bool whitelisted) public whitelistedSenders;

    /// @notice Indicates whether the l2Contract is blacklisted from being called via L1->L2 transactions.
    mapping(address l2Contract => bool blocklisted) public blocklistedContracts;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgeHub, address _assetRouter) {
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

    /// @notice Blocklist an L2 contract
    /// @param _l2Contract The contract to blocklist 
    function blocklistL2Contract(address _l2Contract) external onlyOwner {
        if (blocklistedContracts[_l2Contract]) {
            revert AlreadyBlocklisted(_l2Contract);
        }
        blocklistedContracts[_l2Contract] = true;

        emit Blocklisted(_l2Contract);
    }

    /// @notice Removes an L2 contract from the blocklist
    /// @param _l2Contract The contract to remote from the blocklist
    function removeFromBlocklist(address _l2Contract) external onlyOwner {
        if (!blocklistedContracts[_l2Contract]) {
            revert NotBlocklisted(_l2Contract);
        }
        blocklistedContracts[_l2Contract] = false;
        emit RemovedFromBlocklist(_l2Contract);
    }

    /// @notice Checks if the transaction is allowed
    /// @param sender The sender of the transaction
    /// @param l2Calldata The calldata of the L2 transaction
    /// @return Whether the transaction is allowed
    function isTransactionAllowed(
        address sender,
        address contractL2,
        uint256,
        uint256,
        bytes calldata l2Calldata,
        address
    ) external view returns (bool) {
        if (sender == L1_ASSET_ROUTER) {
            bytes4 l2TxSelector = bytes4(l2Calldata[:4]);

            if (IL2AssetRouter.setAssetHandlerAddress.selector == l2TxSelector) {
                (, bytes32 decodedAssetId, ) = abi.decode(l2Calldata[4:], (uint256, bytes32, address));
                return _checkCTMAssetId(decodedAssetId);
            }

            if (IAssetRouterBase.finalizeDeposit.selector != l2TxSelector) {
                revert InvalidSelector(l2TxSelector);
            }

            (, bytes32 decodedAssetId, ) = abi.decode(l2Calldata[4:], (uint256, bytes32, bytes));
            return _checkCTMAssetId(decodedAssetId);
        }

        if (blocklistedContracts[contractL2]) {
            return false;
        }

        // We always allow calls to the L2AssetRouter contract. We expect that it will not
        // cause deploying of any unwhitelisted code, but it is needed to facilitate withdrawals of chains.
        if (contractL2 > MIN_ALLOWED_ADDRESS || contractL2 == L2_ASSET_ROUTER_ADDR) {
            return true;
        }

        // Only whitelisted senders are allowed to use any built-in contracts.
        return whitelistedSenders[sender];
    }

    function _checkCTMAssetId(bytes32 assetId) internal view returns (bool) {
        address ctmAddress = BRIDGE_HUB.ctmAssetIdToAddress(assetId);
        return ctmAddress != address(0);
    }
}
