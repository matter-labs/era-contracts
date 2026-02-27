// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @title IBaseTokenHolder
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface for the BaseTokenHolder contract that holds the chain's base token reserves.
///
/// ## Base Token Minting via MINT_BASE_TOKEN_HOOK (ZK OS only)
///
/// To mint base tokens on ZK OS chains, call the MINT_BASE_TOKEN_HOOK with the amount to mint encoded as uint256:
/// `(bool success, ) = MINT_BASE_TOKEN_HOOK.call(abi.encode(amountToMint));`
/// The hook will credit the caller (L2BaseToken contract) with the specified amount of native tokens.
/// After minting, the tokens can be transferred using Address.sendValue() or regular ETH transfers.
///
/// This hook is used during genesis/upgrade to initialize the BaseTokenHolder balance:
/// 1. L2BaseTokenZKOS.initializeBaseTokenHolderBalance() calls this hook to mint 2^127-1 tokens
/// 2. The minted tokens are then transferred to L2_BASE_TOKEN_HOLDER_ADDR
/// 3. This establishes the initial token supply invariant for the chain
///
/// Authorization:
/// - The hook validates that msg.sender is L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR (0x800A)
/// - L2BaseTokenZKOS restricts initializeBaseTokenHolderBalance() to L2_COMPLEX_UPGRADER_ADDR only
interface IBaseTokenHolder {
    /// @notice Gives out base tokens from the holder to a recipient.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    function give(address _to, uint256 _amount) external;

    /// @notice Receives base tokens and initiates bridging by notifying L2AssetTracker.
    /// @dev Called by InteropHandler, InteropCenter, NativeTokenVault, and L2BaseToken during bridging operations.
    /// @param _toChainId The chain ID which the funds are sent to. L1 chain ID is not accessible within this
    /// contract, so we use 0 as a placeholder to keep the initialization of the contract simpler.
    function burnAndStartBridging(uint256 _toChainId) external payable;
}
