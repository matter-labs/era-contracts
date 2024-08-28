// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {INativeTokenVault} from "./INativeTokenVault.sol";
import {IL1NativeTokenVault} from "./IL1NativeTokenVault.sol";

// import {IL1AssetRouter} from "./IL1AssetRouter.sol";
// import {IL1AssetHandler} from "./IL1AssetHandler.sol";
// import {IL1BaseTokenAssetHandler} from "./IL1BaseTokenAssetHandler.sol";

/// @title L1 Native token vault contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1NativeTokenVaultCombined is IL1NativeTokenVault, INativeTokenVault {}
