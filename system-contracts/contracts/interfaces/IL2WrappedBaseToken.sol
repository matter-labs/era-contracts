// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

interface IL2WrappedBaseToken {
    /// @notice Initializes a contract token for later use. Expected to be used in the proxy.
    /// @notice This function is used to integrate the previously deployed WETH token with the bridge.
    /// @dev Sets up `name`/`symbol`/`decimals` getters.
    /// @param name_ The name of the token.
    /// @param symbol_ The symbol of the token.
    /// @param _l2Bridge Address of the L2 bridge
    /// @param _l1Address Address of the L1 token that can be deposited to mint this L2 WETH.
    /// Note: The decimals are hardcoded to 18, the same as on Ether.
    function initializeV3(
        string calldata name_,
        string calldata symbol_,
        address _l2Bridge,
        address _l1Address,
        bytes32 _baseTokenAssetId
    ) external;
}
