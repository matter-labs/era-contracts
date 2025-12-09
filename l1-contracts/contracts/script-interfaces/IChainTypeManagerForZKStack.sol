// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IChainTypeManagerForZKStack
/// @notice Interface for Chain Type Manager specifically for zkStack CLI usage
/// @dev This interface includes methods that may be legacy or specific to zkStack CLI needs
interface IChainTypeManagerForZKStack {
    /// @notice Returns the validator timelock address
    function validatorTimelock() external view returns (address);

    /// @notice Returns the validator timelock address for post-v29 chains
    /// @dev This method may be used for backward compatibility with migration scripts
    function validatorTimelockPostV29() external view returns (address);

    /// @notice Handles forwarded mints from the bridgehub
    /// @param _chainId The chain Id
    /// @param _ctmData Additional CTM data
    function forwardedBridgeMint(uint256 _chainId, bytes calldata _ctmData) external returns (address);

    /// @notice Returns the server notifier address
    function serverNotifierAddress() external view returns (address);

    /// @notice Returns the protocol version
    function protocolVersion() external view returns (uint256);
}
