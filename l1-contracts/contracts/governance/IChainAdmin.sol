// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAdmin} from "../state-transition/chain-interfaces/IAdmin.sol";

/// @title ChainAdmin contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainAdmin {
    /// @dev Represents a call to be made during multicall.
    /// @param target The address to which the call will be made.
    /// @param value The amount of Ether (in wei) to be sent along with the call.
    /// @param data The calldata to be executed on the `target` address.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice Emitted when the expected upgrade timestamp for a specific protocol version is set.
    event UpdateUpgradeTimestamp(uint256 indexed _protocolVersion, uint256 _upgradeTimestamp);

    /// @notice Emitted when the call is executed from the contract.
    event CallExecuted(Call _call, bool _success, bytes _returnData);

    function setUpgradeTimestamp(uint256 _protocolVersion, uint256 _upgradeTimestamp) external;

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
