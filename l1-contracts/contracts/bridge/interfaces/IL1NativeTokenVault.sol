// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {INullifier} from "./INullifier.sol";
import {INativeTokenVault} from "./INativeTokenVault.sol";

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The NTV is an Asset Handler for the L1AssetRouter to handle native tokens
interface IL1NativeTokenVault is INativeTokenVault {

    /// @notice The L1Nullifier contract
    function NULLIFIER() external view returns (INullifier);

    /// @notice The weth contract
    function L1_WETH_TOKEN() external view returns (address);
}
