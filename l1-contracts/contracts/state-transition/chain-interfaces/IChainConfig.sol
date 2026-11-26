// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IZKChainBase} from "./IZKChainBase.sol";
import {IChainConfigApplier} from "./IChainConfigApplier.sol";
import {ChainConfigUpdate} from "../chain-deps/ZKChainStorage.sol";

/// @title The interface of the ChainConfig Contract that schedules and applies configuration updates.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainConfig is IZKChainBase, IChainConfigApplier {
    /// @notice The admin scheduled a configuration update, applicable from `timestamp`.
    event ChainConfigUpdateScheduled(ChainConfigUpdate update, uint256 timestamp);

    /// @notice The admin cancelled the pending configuration update.
    event ChainConfigUpdateCancelled();

    /// @notice The pending configuration update was applied.
    event ChainConfigUpdateApplied(ChainConfigUpdate update);

    /// @notice Schedules a configuration update that a validator holding the ValidatorTimelock's `UPGRADER_ROLE`
    /// applies once `_timestamp` has passed, replacing any update that is not yet due.
    /// See {protocol-docs/chain-config.md#scheduled-configuration-updates}.
    /// @param _update The target values of the configuration the update covers.
    /// @param _timestamp The timestamp from which the update can be applied.
    function scheduleChainConfigUpdate(ChainConfigUpdate calldata _update, uint256 _timestamp) external;

    /// @notice Cancels the pending configuration update.
    /// @dev Cancelling an update that is due strands the blocks a node already produced under it.
    /// See {protocol-docs/chain-config.md#scheduled-configuration-updates}.
    function cancelChainConfigUpdate() external;

    /// @inheritdoc IChainConfigApplier
    function applyChainConfigUpdate(address _chainAddress) external override;
}
