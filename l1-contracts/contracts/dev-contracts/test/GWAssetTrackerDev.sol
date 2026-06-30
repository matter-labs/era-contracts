// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GWAssetTracker} from "../../bridge/asset-tracker/GWAssetTracker.sol";

/// @dev Dev-only extension of GWAssetTracker that keeps local-testing helpers out of production bytecode.
// solhint-disable-next-line no-empty-blocks
contract GWAssetTrackerDev is GWAssetTracker {

}
