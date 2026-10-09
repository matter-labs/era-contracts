// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L1 interop fee switch: per-chain prepaid balances that chains are charged from when their batches
/// execute. See {protocol-docs/interop-fee.md}.
interface IInteropFeeManager {
    /// @notice Emitted when the owner changes the fee charged per interop fee unit.
    event NewFeePerUnit(uint256 oldFeePerUnit, uint256 newFeePerUnit);

    /// @notice Emitted when the recipient of swept fees is set.
    event NewFeeRecipient(address indexed oldFeeRecipient, address indexed newFeeRecipient);

    /// @notice Emitted when a chain's prepaid balance is topped up.
    event ChainBalanceDeposited(uint256 indexed chainId, address indexed from, uint256 amount);

    /// @notice Emitted when a chain admin withdraws from the chain's prepaid balance.
    event ChainBalanceWithdrawn(uint256 indexed chainId, address indexed to, uint256 amount);

    /// @notice Emitted when an executed batch is charged.
    event InteropFeeCharged(uint256 indexed chainId, uint256 indexed batchNumber, uint256 units, uint256 fee);

    /// @notice Emitted when the accrued fees are sent to the fee recipient.
    event FeesSwept(address indexed recipient, uint256 amount);

    /// @notice Fee in wei charged per interop fee unit. Zero means the switch is off.
    function feePerUnit() external view returns (uint256);

    /// @notice Address that receives swept fees.
    function feeRecipient() external view returns (address);

    /// @notice Fees charged from chains and not yet swept to the fee recipient.
    function accruedFees() external view returns (uint256);

    /// @notice Prepaid balance of a chain, in wei.
    /// @param _chainId The chain id.
    function chainBalance(uint256 _chainId) external view returns (uint256);

    /// @notice Sets the fee charged per interop fee unit. Only callable by the owner.
    /// @param _feePerUnit The new fee in wei per unit; zero turns the switch off.
    function setFeePerUnit(uint256 _feePerUnit) external;

    /// @notice Sets the recipient of swept fees. Only callable by the owner.
    /// @param _feeRecipient The new recipient.
    function setFeeRecipient(address _feeRecipient) external;

    /// @notice Tops up the prepaid balance of a registered chain. Callable by anyone.
    /// @param _chainId The chain to credit.
    function deposit(uint256 _chainId) external payable;

    /// @notice Withdraws from a chain's prepaid balance. Only callable by the chain admin.
    /// @param _chainId The chain to debit.
    /// @param _to The receiver of the withdrawn funds.
    /// @param _amount The amount in wei.
    function withdraw(uint256 _chainId, address _to, uint256 _amount) external;

    /// @notice Charges `feePerUnit * _units` from the chain's prepaid balance; a no-op while the fee is zero.
    /// Otherwise only callable by the chain's diamond proxy, and reverts if the balance does not cover the fee.
    /// @param _chainId The chain being charged.
    /// @param _batchNumber The executed batch the units belong to.
    /// @param _units The interop fee units the batch sent.
    function chargeInteropFee(uint256 _chainId, uint256 _batchNumber, uint256 _units) external;

    /// @notice Sends all accrued fees to the fee recipient. Callable by anyone.
    function sweep() external;
}
