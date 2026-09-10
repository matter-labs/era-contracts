// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the L2AssetRouter contract.
 * @dev Retained so the `L2_ASSET_ROUTER` address constant in {Contracts} keeps a type. It previously
 * declared `L2_LEGACY_SHARED_BRIDGE()`, which was removed together with legacy bridging — that getter is
 * now a private deprecated storage slot on `L2AssetRouter` and is no longer callable, so advertising it
 * here would hand downstream consumers a selector that reverts.
 */
interface IL2AssetRouter {}
