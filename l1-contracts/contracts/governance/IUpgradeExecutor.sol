// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Call} from "./Common.sol";

/// @title UpgradeExecutor interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IUpgradeExecutor {
    /// @notice Emitted after an upgrade orchestrator module was successfully delegatecalled.
    /// @param module The address of the executed module.
    /// @param data The calldata the module was executed with.
    event UpgradeModuleExecuted(address indexed module, bytes data);

    /// @notice Emitted for every raw call forwarded through the escape hatch.
    /// @param target The address the call was forwarded to.
    /// @param value The ETH value the call carried.
    /// @param data The forwarded calldata.
    event CallForwarded(address indexed target, uint256 value, bytes data);

    /// @notice Delegatecalls a stateless, per-upgrade orchestrator module.
    /// @dev The module executes with this contract's identity, i.e. with every ownership and
    ///      admin right that was handed over to the executor. Modules MUST be stateless: the
    ///      executor verifies that its ownership slots are unchanged after the call and reverts
    ///      otherwise.
    /// @param _module The audited orchestrator module to delegatecall.
    /// @param _data The calldata to execute the module with (typically an orchestrator entrypoint
    ///        taking a registry implementation address).
    /// @return returnData The module's return data.
    function execute(address _module, bytes calldata _data) external payable returns (bytes memory returnData);

    /// @notice Escape hatch: forwards raw calls so that governance never loses direct control
    ///         over the contracts owned by the executor (one-off actions, emergency paths).
    /// @param _calls The calls to forward, executed in order; reverts on the first failure.
    function forward(Call[] calldata _calls) external payable;
}
