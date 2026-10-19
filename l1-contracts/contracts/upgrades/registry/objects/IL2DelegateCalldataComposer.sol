// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICTMRelease} from "./ICTMRelease.sol";

/// @title IL2DelegateCalldataComposer
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The version-specific code that DEFINES the arguments of an upgrade's L2 delegate
///         call. A transition names one of these instead of authored calldata bytes: the
///         delegate's own code is committed by its bytecode hash, and what that code is called
///         WITH is defined by audited code reading authoritative inputs — the target release, the
///         ecosystem's Bridgehub and the chain being upgraded — so governance reviews a contract,
///         not a hex blob.
/// @dev The result is the FINAL calldata for `_chainId`: the per-chain fields (the chain-specific
///      force deployment data) are read from L1 state here, in the one place the transaction is
///      composed — the engine commits it as is.
interface IL2DelegateCalldataComposer {
    /// @param _newRelease The release the upgrade installs (the source of ecosystem-wide data such
    ///        as its `fixedForceDeploymentsData`).
    /// @param _bridgehub The ecosystem's Bridgehub (the source of live ecosystem addresses and of
    ///        the chain's base-token registration).
    /// @param _chainId The chain the transaction is composed for.
    function composeDelegateCalldata(
        ICTMRelease _newRelease,
        address _bridgehub,
        uint256 _chainId
    ) external view returns (bytes memory);
}
