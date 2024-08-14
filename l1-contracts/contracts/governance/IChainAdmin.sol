// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import { Call } from "./Common.sol";

/// @title ChainAdmin contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainAdmin {
    /// @notice Emitted when the expected upgrade timestamp for a specific protocol version is set.
    event UpdateUpgradeTimestamp(uint256 indexed _protocolVersion, uint256 _upgradeTimestamp);

    /// @notice Emitted when the call is executed from the contract.
    event CallExecuted(Call _call, bool success, bytes returnData);

    function getRestrictions() external view returns (address[] memory);

    function isRestrictionActive(address) external view returns (bool);

    function addRestriction(address restriction) external;

    function removeRestriction(address restriction) external;
}
