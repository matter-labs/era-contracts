// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {IL2BaseTokenBase} from "../../interfaces/IL2BaseTokenBase.sol";

/// @title IL2BaseTokenZKOS
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface for the L2 Base Token contract on ZK OS chains.
/// @dev Extends IL2BaseTokenBase with ZKOS-specific functionality.
interface IL2BaseTokenZKOS is IL2BaseTokenBase {
    /// @notice The total supply that existed before the V31 upgrade, backfilled during v31.
    function zkosPreV31TotalSupply() external view returns (uint256);
}
