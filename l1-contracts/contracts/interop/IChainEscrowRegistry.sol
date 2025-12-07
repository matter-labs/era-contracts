// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IChainEscrowRegistry
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface for the chain escrow registry that manages ZK token escrows for interop settlement fees
/// @dev This escrow system ensures permissionless interop settlement by preventing operator rotation attacks.
///      Settlement fees are deducted from chain-specific escrows rather than operator addresses directly,
///      allowing community funding and preventing settlement blocking by malicious operators.
interface IChainEscrowRegistry {
    /// @notice Emitted when ZK tokens are deposited into a chain's escrow
    /// @param chainId The chain ID for which tokens were deposited
    /// @param depositor The address that made the deposit
    /// @param amount The amount of ZK tokens deposited
    event EscrowDeposited(uint256 indexed chainId, address indexed depositor, uint256 amount);

    /// @notice Emitted when settlement fees are paid from escrow
    /// @param chainId The chain ID from which fees were paid
    /// @param amount The amount of fees paid
    event SettlementFeePaid(uint256 indexed chainId, uint256 amount);

    /// @notice Emitted when an operator withdraws from escrow
    /// @param chainId The chain ID from which funds were withdrawn
    /// @param operator The operator who withdrew
    /// @param amount The amount of ZK tokens withdrawn
    event OperatorWithdrawal(uint256 indexed chainId, address indexed operator, uint256 amount);

    /// @notice Data structure for chain escrow information
    struct ChainEscrow {
        uint256 balance; // Available balance
    }

    /// @notice Deposit ZK tokens into a chain's escrow (permissionless - anyone can fund any chain)
    /// @dev This enables community funding to ensure settlement availability even if operators are unresponsive
    /// @param chainId The chain ID to deposit for
    /// @param amount The amount of ZK tokens to deposit
    function deposit(uint256 chainId, uint256 amount) external;

    /// @notice Pay settlement fees from chain escrow (only callable by asset tracker)
    /// @dev Directly deducts fees from the chain's escrow balance and transfers to this contract
    /// @param chainId The chain ID to pay fees for
    /// @param amount The amount of fees to pay
    function paySettlementFees(uint256 chainId, uint256 amount) external;

    /// @notice Withdraw funds from chain escrow (only callable by chain admin, max once per day)
    /// @param chainId The chain ID to withdraw from
    /// @param amount The amount to withdraw
    function withdraw(uint256 chainId, uint256 amount) external;

    /// @notice Get escrow information for a chain
    /// @param chainId The chain ID to query
    /// @return escrow The chain's escrow data
    function getChainEscrow(uint256 chainId) external view returns (ChainEscrow memory escrow);

    /// @notice Get the available balance for a chain
    /// @param chainId The chain ID to query
    /// @return The available balance
    function getAvailableBalance(uint256 chainId) external view returns (uint256);
}
