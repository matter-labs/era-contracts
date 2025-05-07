// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the BridgedStandardERC20 contract
 */
interface IBridgedStandardERC20 {
    /// @dev Describes whether there is a specific getter in the token.
    /// @notice Used to explicitly separate which getters the token has and which it does not.
    /// @notice Different tokens in L1 can implement or not implement getter function as `name`/`symbol`/`decimals`,
    /// @notice Our goal is to store all the getters that L1 token implements, and for others, we keep it as an unimplemented method.
    struct ERC20Getters {
        bool ignoreName;
        bool ignoreSymbol;
        bool ignoreDecimals;
    }

    /// @notice A method to be called by the governor to update the token's metadata.
    /// @param _availableGetters The getters that the token has.
    /// @param _newName The new name of the token.
    /// @param _newSymbol The new symbol of the token.
    /// @param _version The version of the token that will be initialized.
    /// @dev The _version must be exactly the version higher by 1 than the current version. This is needed
    /// to ensure that the governor can not accidentally disable future reinitialization of the token.
    function reinitializeToken(
        ERC20Getters calldata _availableGetters,
        string calldata _newName,
        string calldata _newSymbol,
        uint8 _version
    ) external;
}
