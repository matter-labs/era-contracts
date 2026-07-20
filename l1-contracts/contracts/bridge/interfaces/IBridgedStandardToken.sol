// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @title Bridged standard token interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The mint/burn interface implemented by bridged token contracts, called by the native token
/// vault. See {protocol-docs/bridging.md}.
interface IBridgedStandardToken {
    event BridgeInitialize(address indexed l1Token, string name, string symbol, uint8 decimals);

    event BridgeMint(address indexed account, uint256 amount);

    event BridgeBurn(address indexed account, uint256 amount);

    /// @notice Mints tokens to the given account when a bridged-in transfer is finalized.
    /// @param _account The account that receives the minted tokens.
    /// @param _amount The amount to mint.
    function bridgeMint(address _account, uint256 _amount) external;

    /// @notice Burns tokens from the given account when bridging out.
    /// @param _account The account the tokens are burned from.
    /// @param _amount The amount to burn.
    function bridgeBurn(address _account, uint256 _amount) external;

    /// @notice The token on the origin chain that this bridged token represents.
    function originToken() external view returns (address);

    /// @notice Deprecated legacy L2 bridge address; the native token vault is the trustee now.
    function l2Bridge() external view returns (address);

    /// @notice The asset ID of the token.
    function assetId() external view returns (bytes32);

    /// @notice The native token vault allowed to mint/burn this token.
    function nativeTokenVault() external view returns (address);
}
