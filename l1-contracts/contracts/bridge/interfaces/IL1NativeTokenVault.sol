// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1Nullifier} from "./IL1Nullifier.sol";
import {INativeTokenVault} from "./INativeTokenVault.sol";

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The NTV is an Asset Handler for the L1AssetRouter to handle native tokens
interface IL1NativeTokenVault is INativeTokenVault {
    /// @notice The L1Nullifier contract
    function NULLIFIER() external view returns (IL1Nullifier);
}
