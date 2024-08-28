// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IAssetRouterBase} from "./IAssetRouterBase.sol";
import {IL1AssetRouter} from "./IL1AssetRouter.sol";

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1AssetRouterCombined is IAssetRouterBase, IL1AssetRouter {}
