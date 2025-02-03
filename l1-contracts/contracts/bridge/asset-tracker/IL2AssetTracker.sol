// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IAssetTrackerBase} from "../asset-tracker/IAssetTrackerBase.sol";

interface IL2AssetTracker is IAssetTrackerBase {

}