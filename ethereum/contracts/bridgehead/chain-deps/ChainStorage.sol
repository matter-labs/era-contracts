// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import "./Verifier.sol";
import "../../common/interfaces/IAllowList.sol";
import "../../common/Messaging.sol";

/// @dev storing all storage variables for chain
/// NOTE: It is used in a proxy, so it is possible to add new variables to the end
/// but NOT to modify already existing variables or change their order.
/// NOTE: variables prefixed with '__DEPRECATED_' are deprecated and shouldn't be used.
/// Their presence is maintained for compatibility and to prevent storage collision.
struct ChainStorage {
    /// @notice Address which will exercise governance over the network i.e. change validator set, conduct upgrades
    address governor;
    /// @notice Address that the governor proposed as one that will replace it
    address pendingGovernor;
    /// @notice chainIds
    uint256 chainId;
    /// @notice The bridgehead Contract
    address bridgehead;
    /// @notice The proof System
    address proofSystem;
    /// @dev The smart contract that manages the list with permission to call contract functions
    IAllowList allowList;
}
