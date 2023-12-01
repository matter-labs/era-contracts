// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../chain-interfaces/IVerifier.sol";
import "../Verifier.sol";
import "../../common/interfaces/IAllowList.sol";
import "../../common/Messaging.sol";

/// @dev storing all storage variables for zkSync facets
/// NOTE: It is used in a proxy, so it is possible to add new variables to the end
/// but NOT to modify already existing variables or change their order.
/// NOTE: variables prefixed with '__DEPRECATED_' are deprecated and shouldn't be used.
/// Their presence is maintained for compatibility and to prevent storage collision.
struct StateTransitionStorage {
    /// @notice Address which will exercise governance over the network i.e. change validator set, conduct upgrades
    address governor;
    /// @notice Address that the governor proposed as one that will replace it
    address pendingGovernor;
    /// @notice Address of the factory
    address bridgehub;
    uint256 totalChains;
    mapping(uint256 => address) chainNumberToContract;
    /// @notice chainId => chainContract
    mapping(uint256 => address) stateTransitionChainContract;
    /// @dev Batch hash zero, calculated at initialization
    bytes32 storedBatchZero;
    /// @dev Stored cutData for diamond cut
    bytes32 cutHash;
    /// @dev Diamond Init address for setChainId
    address diamondInit;
    /// @dev Stored cutData for upgrade diamond cut. protocolVersion => cutHash
    mapping(uint256 => bytes32) upgradeCutHash;
    /// @dev protocolVersion
    uint256 protocolVersion;
}
