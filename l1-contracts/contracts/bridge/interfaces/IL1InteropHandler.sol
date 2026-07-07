// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL1AssetRouter} from "../asset-router/IL1AssetRouter.sol";
import {FinalizeL1DepositParams} from "../../common/Messaging.sol";

/// @dev Transient storage slot for storing the settlement layer chain ID during proof verification.
/// @dev This slot is used to temporarily store which settlement layer is processing the current proof,
/// @dev and is cleared at the end of each transaction.
uint256 constant TRANSIENT_SETTLEMENT_LAYER_SLOT = uint256(keccak256("TRANSIENT_SETTLEMENT_LAYER_SLOT")) - 1;

/// @title L1 Interop Handler interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Entry point that finalizes L2 -> L1 withdrawals on L1. Every withdrawal (base token and ERC20) is
/// emitted by the L2 InteropCenter as a single-call interop bundle; this contract proves the bundle's inclusion,
/// parses it, enforces replay protection and dispatches the finalization to the L1 asset router.
interface IL1InteropHandler {
    event TransientSettlementLayerSet(uint256 indexed settlementLayerChainId);

    /// @notice Tracks the processing status of L2 to L1 messages, indicating whether a message has already been finalized.
    function isWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex
    ) external view returns (bool);

    /// @notice Finalize the withdrawal and release funds.
    /// @param _finalizeWithdrawalParams The structure that holds all necessary data to finalize the withdrawal.
    function finalizeDeposit(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external;

    /// @notice The L1 asset router that finalizations are dispatched to.
    function l1AssetRouter() external view returns (IL1AssetRouter);

    /// @notice The L1 nullifier that is allowed to record the transient settlement layer for its recovery flow.
    function l1Nullifier() external view returns (address);

    /// @notice Sets the L1 asset router contract address. Should be called only once by the owner.
    function setL1AssetRouter(address _l1AssetRouter) external;

    /// @notice Sets the L1 nullifier contract address. Should be called only once by the owner.
    function setL1Nullifier(address _l1Nullifier) external;

    /// @notice Records the transient settlement layer for the current transaction.
    /// @dev Restricted to the L1 nullifier, which uses it while confirming failed-deposit recovery. The withdrawal
    /// finalization path records the value itself during `finalizeDeposit`.
    /// @param _settlementLayerChainId The chain ID of the settlement layer that processed the proof.
    /// @param _l2BatchNumber The L2 batch number the proof was included in.
    function setTransientSettlementLayer(uint256 _settlementLayerChainId, uint256 _l2BatchNumber) external;

    /// @notice When verifying recursive proofs, we mark the transient settlement layer,
    /// this function retrieves the currently stored transient settlement layer chain ID.
    /// @dev The transient settlement layer is cleared at the end of each transaction.
    /// @dev Note, that it is hard assumption that must be enforced by all the users of this function:
    /// Any operations that reads this value, must be preceded by a successful invocation of L1InteropHandler
    /// (directly, or via the L1 nullifier recovery flow) that has set this value. Otherwise, it is possible that the
    /// same value is reused multiple times.
    /// @return The chain ID of the settlement layer that processed the current proof, or 0 if none is set.
    function getTransientSettlementLayer() external view returns (uint256, uint256);
}
