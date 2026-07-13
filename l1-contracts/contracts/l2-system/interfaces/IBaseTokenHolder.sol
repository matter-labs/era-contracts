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
/// 1. L2BaseTokenZKOS.initL2() calls this hook to mint 2^127-1 tokens
/// 2. The minted tokens are then transferred to L2_BASE_TOKEN_HOLDER_ADDR
/// 3. This establishes the initial token supply invariant for the chain
///
/// Authorization:
/// - The hook validates that msg.sender is L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR (0x800A)
/// - L2BaseTokenZKOS restricts initL2() to L2_COMPLEX_UPGRADER_ADDR only
interface IBaseTokenHolder {
    /// @notice Emitted when base tokens are given out from the holder via interop bridging.
    /// @dev This event is only emitted for inbound bridging through BaseTokenHolder.give().
    /// @dev On Era, L1 deposits go through L2BaseTokenEra.mint() which does NOT emit this event.
    /// @dev Therefore, the sum of BaseTokenMintedInterop amounts may not equal the total inbound base token volume.
    /// @param to The address that received the base tokens.
    /// @param amount The amount of base tokens given out.
    event BaseTokenMintedInterop(address indexed to, uint256 amount);

    /// @notice Emitted when base tokens are received and outbound bridging is initiated.
    /// @dev Emitted for outbound base-token bridging through BaseTokenHolder.burnAndStartBridging(), which is now
    /// the unified path on both Era and ZK OS: base-token L2->L1 withdrawals and cross-chain sends flow through
    /// the InteropCenter, and bridged base-token burns through the NativeTokenVault — both call
    /// burnAndStartBridging. (The dedicated L2BaseToken withdraw entrypoint that used to bypass this contract on
    /// Era was removed, so Era withdrawals now route through here too.)
    /// @param from The address that sent the base tokens.
    /// @param toChainId The destination chain ID for the bridging operation.
    /// @param amount The amount of base tokens burnt.
    event BaseTokenBurntInterop(address indexed from, uint256 toChainId, uint256 amount);

    /// @notice Emitted when base tokens escrowed by a failed/timed-out bridge-out are returned to the depositor.
    /// @param to The original depositor refunded.
    /// @param amount The amount of base tokens returned.
    event BaseTokenRecovered(address indexed to, uint256 amount);

    /// @notice Gives out base tokens from the holder to a recipient.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    /// @param _fromChainId The source chain ID of the bridging operation.
    function give(address _to, uint256 _amount, uint256 _fromChainId) external;

    /// @notice Returns base tokens escrowed by a failed/timed-out bridge-out to the original depositor.
    /// @dev Callable only by the NativeTokenVault; reverses the source-side bridging accounting.
    /// @param _to The original depositor to refund.
    /// @param _amount The amount of base tokens to return.
    /// @param _toChainId The original bridge-out destination chain id.
    function recoverBaseToken(address _to, uint256 _amount, uint256 _toChainId) external;

    /// @notice Receives base tokens and initiates bridging by notifying L2AssetTracker.
    /// @dev Called by InteropCenter and NativeTokenVault during bridging operations.
    /// @param _toChainId The chain ID which the funds are sent to.
    function burnAndStartBridging(uint256 _toChainId) external payable;
}
