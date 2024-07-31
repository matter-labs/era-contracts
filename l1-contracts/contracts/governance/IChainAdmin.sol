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

    /// @notice Emitted when the new token multiplier address is set.
    event NewTokenMultiplierSetter(address _oldTokenMultiplierSetter, address _newTokenMultiplierSetter);

    function setTokenMultiplierSetter(address _tokenMultiplierSetter) external;

    function setUpgradeTimestamp(uint256 _protocolVersion, uint256 _upgradeTimestamp) external;

    function multicall(Call[] calldata _calls, bool _requireSuccess) external payable;

    function setTokenMultiplier(IAdmin _chainContract, uint128 _nominator, uint128 _denominator) external;
}
