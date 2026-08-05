// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {SavedTotalSupply} from "../../common/L2AssetBookkeeping.sol";

/// @title IBaseTokenHolder
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface for the BaseTokenHolder contract that holds the chain's base-token reserve.
/// See {protocol-docs/bridging.md#base-token-handling}.
/// @dev On ZK OS the holder's initial 2^127 - 1 balance is minted by `L2BaseTokenZKOS.initL2()` via the
/// MINT_BASE_TOKEN_HOOK — a raw call with the amount abi-encoded as uint256, which credits the caller and
/// only accepts calls from the L2BaseToken address — and is then transferred here.
interface IBaseTokenHolder {
    /// @notice Emitted when base tokens are given out from the holder via interop bridging.
    /// @dev Only emitted for inbound bridging through `give`. On Era, L1 deposits mint through
    /// `L2BaseTokenEra.mint()` without this event, so summing it may undercount total inbound volume.
    /// @param to The address that received the base tokens.
    /// @param amount The amount of base tokens given out.
    event BaseTokenMintedInterop(address indexed to, uint256 amount);

    /// @notice Emitted when base tokens are received and outbound bridging is initiated.
    /// @dev Emitted on the unified outbound path (`burnAndStartBridging`) on both Era and ZK OS:
    /// withdrawals initiated through L2BaseToken and cross-chain sends initiated through
    /// InteropCenter or NativeTokenVault all converge there.
    /// @param from The address that sent the base tokens.
    /// @param toChainId The destination chain ID for the bridging operation.
    /// @param amount The amount of base tokens burnt.
    event BaseTokenBurntInterop(address indexed from, uint256 toChainId, uint256 amount);

    /// @notice Emitted when base tokens escrowed by a failed/timed-out bridge-out are returned to the depositor.
    /// @param to The original depositor refunded.
    /// @param amount The amount of base tokens returned.
    event BaseTokenRecovered(address indexed to, uint256 amount);

    /// @notice Gives out base tokens from the holder to a recipient (replaces minting).
    /// @dev Pushes ETH with a plain transfer, so it reverts if the recipient rejects it — only trusted
    /// recipients should be used.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    /// @param _fromChainId The source chain ID of the bridging operation.
    function give(address _to, uint256 _amount, uint256 _fromChainId) external;

    /// @notice Returns base tokens escrowed by a failed/timed-out bridge-out to the original depositor.
    /// @dev Callable only by the NativeTokenVault (atomic-interop timeout recovery); see
    /// {protocol-docs/bridging.md#base-token-handling}. Like `give`, this pushes ETH and may revert if
    /// `_to` rejects it — recovery targets the original depositor by design.
    /// @param _to The original depositor to refund.
    /// @param _amount The amount of base tokens to return.
    /// @param _toChainId The original bridge-out destination chain id (to reverse the matching accounting).
    function recoverBaseToken(address _to, uint256 _amount, uint256 _toChainId) external;

    /// @notice Receives outbound base-token value and records the outbound flow (replaces burning).
    /// @dev Called by InteropCenter, NativeTokenVault, and L2BaseToken during bridging operations.
    /// @param _toChainId The chain ID which the funds are sent to.
    function burnAndStartBridging(uint256 _toChainId) external payable;

    /// @notice Records an inbound base-token bridge finalized outside this contract.
    /// @dev Callable only by L2BaseToken; used by the Era bootloader deposit path.
    function recordBaseTokenDeposit(uint256 _fromChainId, uint256 _amount) external;

    /// @notice Initializes the pre-bookkeeping base-token supply snapshot.
    /// @dev Callable once by ComplexUpgrader during genesis or the upgrade.
    function initializeBookkeeping(SavedTotalSupply calldata _preTrackingTotalSupply, bool _needsBackfill) external;

    /// @notice Replaces the provisional zero snapshot after a ZKsync OS pre-v31 supply backfill.
    /// @dev Callable only by L2BaseToken.
    function backfillBaseTokenPreTrackingTotalSupply(uint256 _amount) external;

    /// @notice L2-side accounting of base-token L1 <-> L2 flows while this chain settles on L1.
    function baseTokenInteropInfo()
        external
        view
        returns (uint256 totalWithdrawalsToL1, uint256 totalSuccessfulDepositsFromL1);

    /// @notice Supply captured before the first bridge operation tracked by BaseTokenHolder.
    function baseTokenPreTrackingTotalSupply() external view returns (bool isSaved, uint256 amount);

    /// @notice Whether the provisional ZKsync OS snapshot still needs its governance backfill.
    function baseTokenPreTrackingTotalSupplyBackfillPending() external view returns (bool);
}
