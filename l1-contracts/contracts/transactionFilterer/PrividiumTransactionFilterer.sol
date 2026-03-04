// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {AlreadyWhitelisted, NotWhitelisted, ZeroAddress} from "../common/L1ContractErrors.sol";
import {ITransactionFilterer} from "../state-transition/chain-interfaces/ITransactionFilterer.sol";
import {AssetRouterBase} from "../bridge/asset-router/AssetRouterBase.sol";
import {IL2SharedBridgeLegacyFunctions} from "../bridge/interfaces/IL2SharedBridgeLegacyFunctions.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {L2_ASSET_ROUTER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Filters transactions received by the Mailbox
/// @dev Allows only deposits (from anyone), and arbitrary transactions from whitelisted senders.
contract PrividiumTransactionFilterer is ITransactionFilterer, Ownable2StepUpgradeable {
    /// @notice Event emitted when sender is whitelisted
    event WhitelistGranted(address indexed sender);

    /// @notice Event emitted when sender is removed from whitelist
    event WhitelistRevoked(address indexed sender);

    /// @notice Event emitted when depositsAllowed is toggled
    event DepositsPermissionChanged(bool depositsAllowed);

    /// @notice The L1 asset router
    address public immutable L1_ASSET_ROUTER;

    /// @notice Indicates whether the sender is whitelisted to deposit
    mapping(address sender => bool whitelisted) public whitelistedSenders;

    /// @notice Whether deposits are allowed from non-whitelisted addresses
    bool public depositsAllowed;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address _assetRouter) {
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

    /// @notice Sets whether deposits are allowed from non-whitelisted addresses
    /// @param _allowed Whether deposits are allowed from non-whitelisted addresses
    function setDepositsAllowed(bool _allowed) external onlyOwner {
        if (depositsAllowed == _allowed) {
            return;
        }
        depositsAllowed = _allowed;
        emit DepositsPermissionChanged(_allowed);
    }

    /// @notice Whitelists the sender.
    /// @param _sender Address of the tx sender.
    function grantWhitelist(address _sender) external onlyOwner {
        if (whitelistedSenders[_sender]) {
            revert AlreadyWhitelisted(_sender);
        }
        if (_sender == address(0)) {
            revert ZeroAddress();
        }
        whitelistedSenders[_sender] = true;
        emit WhitelistGranted(_sender);
    }

    /// @notice Revoke the sender from whitelist.
    /// @param _sender Address of the tx sender.
    function revokeWhitelist(address _sender) external onlyOwner {
        if (!whitelistedSenders[_sender]) {
            revert NotWhitelisted(_sender);
        }
        whitelistedSenders[_sender] = false;
        emit WhitelistRevoked(_sender);
    }

    /// @notice Checks if the transaction is allowed
    /// @param _sender The sender of the transaction
    /// @param _l2Value The value sent with the L2 transaction
    /// @param _l2Calldata The calldata of the L2 transaction
    /// @return Whether the transaction is allowed
    function isTransactionAllowed(
        address _sender,
        address _contractL2,
        uint256,
        uint256 _l2Value,
        bytes calldata _l2Calldata,
        address
    ) external view returns (bool) {
        // Only whitelisted senders are allowed to perform arbitrary transactions.
        if (whitelistedSenders[_sender]) {
            return true;
        }

        // Since contract addresses are aliased and we require that depositor == receiver,
        // only EOAs, 7702 delegators, or whitelisted contracts will be able to perform deposits.
        if (_sender == L1_ASSET_ROUTER) {
            // Non-base token deposit via `requestL2TransactionTwoBridges`
            if (_l2Value != 0 || _contractL2 != L2_ASSET_ROUTER_ADDR) {
                return false;
            }
            bytes4 l2TxSelector = bytes4(_l2Calldata[:4]);
            if (l2TxSelector == AssetRouterBase.finalizeDeposit.selector) {
                (, , bytes memory data) = abi.decode(_l2Calldata[4:], (uint256, bytes32, bytes));
                // slither-disable-next-line unused-return
                (address depositor, address receiver, , uint256 amount, ) = DataEncoding.decodeBridgeMintData(data);
                return (depositor == receiver && amount > 0 && depositsAllowed) || whitelistedSenders[depositor];
            } else if (l2TxSelector == IL2SharedBridgeLegacyFunctions.finalizeDeposit.selector) {
                // slither-disable-next-line unused-return
                (address depositor, address receiver, , uint256 amount, ) = DataEncoding.decodeBridgeMintData(
                    _l2Calldata[4:]
                );
                return (depositor == receiver && amount > 0 && depositsAllowed) || whitelistedSenders[depositor];
            } else {
                return false;
            }
        } else {
            // Base token deposit via `requestL2TransactionDirect`
            return _contractL2 == _sender && _l2Value > 0 && _l2Calldata.length == 0 && depositsAllowed;
        }
    }
}
