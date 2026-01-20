// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title IGatewayVotePreparation
/// @notice Interface for GatewayVotePreparation.s.sol script
/// @dev This interface ensures selector visibility for GatewayVotePreparation functions
interface IGatewayVotePreparation {
    function run(address bridgehubProxy, uint256 ctmRepresentativeChainId) external;
}
