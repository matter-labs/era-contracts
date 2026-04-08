// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @notice Canonical identifier for core L2 contracts that participate in
///         force-deployments and factory-dependency publishing.
///         The enum value is VM-neutral; `CoreOnGatewayHelper.resolve` maps it to
///         the correct Era or ZKsyncOS contract / artifact name.
enum CoreContract {
    L2Bridgehub,
    L2AssetRouter,
    L2NativeTokenVault,
    L2MessageRoot,
    UpgradeableBeaconDeployer,
    BaseTokenHolder,
    L2ChainAssetHandler,
    InteropCenter,
    InteropHandler,
    L2AssetTracker,
    BeaconProxy,
    L2V29Upgrade,
    L2V31Upgrade,
    L2SharedBridgeLegacy,
    BridgedStandardERC20,
    DiamondProxy,
    ProxyAdmin,
    L2BaseToken
}
