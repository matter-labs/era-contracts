// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {GWAssetTracker} from "../../bridge/asset-tracker/GWAssetTracker.sol";

/// @dev Dev-only extension of GWAssetTracker that keeps local-testing helpers out of production bytecode.
contract GWAssetTrackerDev is GWAssetTracker {
    /// @dev For local testing only.
    function setLegacySharedBridgeAddressForLocalTesting(
        uint256 _chainId,
        address _legacySharedBridgeAddress
    ) external onlyUpgrader {
        legacySharedBridgeAddress[_chainId] = _legacySharedBridgeAddress;
    }
}
