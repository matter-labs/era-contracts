// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Call} from "./Common.sol";

/// @title IUpgradeExecutorBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The surface every domain upgrade executor shares through `UpgradeExecutorBase`: the one
///         raw-call escape hatch that keeps the authority an executor holds reachable.
interface IUpgradeExecutorBase {
    /// @notice Emitted for every raw call forwarded through the escape hatch.
    event CallForwarded(address indexed target, uint256 value, bytes data);

    /// @notice Escape hatch: forwards raw calls so the authority this executor holds (CTM /
    ///         ProxyAdmin ownership) never becomes unreachable — recovery, ownership succession
    ///         and one-off administrative actions outside the fixed entrypoints. Every call is
    ///         logged, so a bypass of the object-driven path is always visible.
    /// @param _calls The calls to forward, executed in order; reverts on the first failure.
    function forward(Call[] calldata _calls) external payable;
}
