// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {ITransactionFilterer} from "../../state-transition/chain-interfaces/ITransactionFilterer.sol";

/// @notice Which generic (non-deposit) L1->L2 calls the filterer lets through.
/// @dev `ALLOW_ALL`: every call passes. `WITHDRAWALS_ONLY`: only calls listed in `withdrawalFunctions`
/// pass, and token deposits are rejected.
enum CallMode {
    ALLOW_ALL,
    WITHDRAWALS_ONLY
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Transaction filterer that enforces the maintenance-mode limits of an EraVM chain.
/// See {docs/era-maintenance-filterer.md}.
interface IEraMaintenanceTransactionFilterer is ITransactionFilterer {
    event CallModeSet(CallMode indexed callMode);

    event ExemptSet(address indexed account, bool exempt);

    event DepositCapSet(bytes32 indexed assetId, uint256 cap);

    event AllowedTxHashSet(bytes32 indexed txHash, bool allowed);

    event WithdrawalFunctionSet(address indexed l2Contract, bytes4 indexed selector, bool allowed);

    event LegacyBridgeSet(address indexed l1Bridge, bool isLegacyBridge);

    /// @notice The chain whose Mailbox uses this filterer.
    function chainId() external view returns (uint256);

    /// @notice The current call mode.
    function callMode() external view returns (CallMode);

    /// @notice Whether the restrictions are lifted for `_account`.
    /// @dev For deposits this is checked against the depositor, not the L1 bridge that sent the message.
    function exempt(address _account) external view returns (bool);

    /// @notice The maximum amount of a single deposit of `_assetId`; zero means the asset is not accepted.
    /// @dev The cap of the chain's base token bounds `mintValue` of every non-exempt L1->L2 transaction.
    function depositCap(bytes32 _assetId) external view returns (uint256);

    /// @notice Whether the exact transaction with this `getTxHash` value is allowed when the other rules reject it.
    function allowedTxHashes(bytes32 _txHash) external view returns (bool);

    /// @notice Whether calls to `_selector` on `_l2Contract` pass in `WITHDRAWALS_ONLY` mode.
    function withdrawalFunctions(address _l2Contract, bytes4 _selector) external view returns (bool);

    /// @notice Whether L1->L2 calls from `_l1Bridge` with the legacy `finalizeDeposit` selector are treated as deposits.
    function legacyBridges(address _l1Bridge) external view returns (bool);

    /// @notice Sets the call mode.
    /// @param _callMode The new call mode.
    function setCallMode(CallMode _callMode) external;

    /// @notice Lifts or restores the restrictions for an account.
    /// @param _account The L1 sender or depositor.
    /// @param _exempt Whether the account is exempt.
    function setExempt(address _account, bool _exempt) external;

    /// @notice Sets the per-deposit caps of several assets.
    /// @param _assetIds The asset ids.
    /// @param _caps The caps; zero stops accepting the asset, `type(uint256).max` removes the cap.
    function setDepositCaps(bytes32[] calldata _assetIds, uint256[] calldata _caps) external;

    /// @notice Allows or disallows one exact transaction.
    /// @param _txHash The value returned by `getTxHash` for the transaction.
    /// @param _allowed Whether the transaction is allowed.
    function setAllowedTxHash(bytes32 _txHash, bool _allowed) external;

    /// @notice Adds or removes a function from the calls allowed in `WITHDRAWALS_ONLY` mode.
    /// @param _l2Contract The L2 contract.
    /// @param _selector The function selector.
    /// @param _allowed Whether calls to the function pass.
    function setWithdrawalFunction(address _l2Contract, bytes4 _selector, bool _allowed) external;

    /// @notice Marks an L1 bridge whose messages use the legacy `finalizeDeposit` ABI, so its deposits are capped.
    /// @param _l1Bridge The L1 bridge, i.e. the `sender` of its L1->L2 transactions.
    /// @param _isLegacyBridge Whether the bridge's deposits are decoded.
    function setLegacyBridge(address _l1Bridge, bool _isLegacyBridge) external;

    /// @notice The key of a transaction in `allowedTxHashes`.
    /// @dev `mintValue` is not part of it, since it includes the L1 base cost.
    /// @param _sender The sender, as passed to `isTransactionAllowed`.
    /// @param _contractL2 The L2 receiver.
    /// @param _l2Value The L2 `msg.value`.
    /// @param _l2Calldata The L2 calldata.
    /// @param _refundRecipient The refund recipient, as passed to `isTransactionAllowed`.
    /// @return The hash.
    function getTxHash(
        address _sender,
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _l2Calldata,
        address _refundRecipient
    ) external pure returns (bytes32);
}
