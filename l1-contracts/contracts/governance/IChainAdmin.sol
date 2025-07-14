// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Call} from "./Common.sol";

/// @title ChainAdmin contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainAdmin {
    /// @notice Emitted when the expected upgrade timestamp for a specific protocol version is set.
    event UpdateUpgradeTimestamp(uint256 indexed protocolVersion, uint256 upgradeTimestamp);

    /// @notice Emitted when the call is executed from the contract.
    event CallExecuted(Call call, bool success, bytes returnData);

    /// @notice Emitted when a new restriction is added.
    event RestrictionAdded(address indexed restriction);

    /// @notice Emitted when a restriction is removed.
    event RestrictionRemoved(address indexed restriction);

    /// @notice The EVM emulator has been enabled
    event EnableEvmEmulator();

    /// @notice Returns the list of active restrictions.
    function getRestrictions() external view returns (address[] memory);

    /// @notice Checks if the restriction is active.
    /// @param _restriction The address of the restriction contract.
    function isRestrictionActive(address _restriction) external view returns (bool);

    /// @notice Adds a new restriction to the active restrictions set.
    /// @param _restriction The address of the restriction contract.
    function addRestriction(address _restriction) external;

    /// @notice Removes a restriction from the active restrictions set.
    /// @param _restriction The address of the restriction contract.
    /// @dev Sometimes restrictions might need to enforce their permanence (e.g. if a chain should be a rollup forever).
    function removeRestriction(address _restriction) external;

    /// @notice Execute multiple calls as part of contract administration.
    /// @param _calls Array of Call structures defining target, value, and data for each call.
    /// @param _requireSuccess If true, reverts transaction on any call failure.
    /// @dev Intended for batch processing of contract interactions, managing gas efficiency and atomicity of operations.
    /// @dev Note, that this function lacks access control. It is expected that the access control is implemented in a separate restriction contract.
    /// @dev Even though all the validation from external modules is executed via `staticcall`, the function
    /// is marked as `nonReentrant` to prevent reentrancy attacks in case the staticcall restriction is lifted in the future.
    function multicall(Call[] calldata _calls, bool _requireSuccess) external payable;
}
