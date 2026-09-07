// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICTMRelease} from "./ICTMRelease.sol";

/// @title IL2DelegateCalldataComposer
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The version-specific, codehash-pinned code that DEFINES the arguments of an upgrade's L2
///         delegate call. A transition pins one of these instead of authored calldata bytes: the
///         delegate's code is pinned by its bytecode hash, and what that code is called WITH is
///         defined by audited code reading authoritative inputs — the target release and the
///         ecosystem's Bridgehub — so governance reviews a contract, not a hex blob.
/// @dev The result is the ECOSYSTEM-WIDE calldata; per-chain fields (the chain-specific force
///      deployment data) stay placeholders that the ZKsync OS upgrade engine rewrites at execution
///      on each chain, exactly as today (`L2UpgradeTxLib.rewriteZKsyncOSUpgradeTxData`).
interface IL2DelegateCalldataComposer {
    /// @param _newRelease The release the upgrade installs (the source of ecosystem-wide data such
    ///        as the pinned `fixedForceDeploymentsData`).
    /// @param _bridgehub The ecosystem's Bridgehub (the source of live ecosystem addresses).
    function composeDelegateCalldata(ICTMRelease _newRelease, address _bridgehub) external view returns (bytes memory);
}
