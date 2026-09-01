// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {FixedForceDeploymentsData} from "../../state-transition/l2-deps/IL2GenesisUpgrade.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L2-side ecosystem registry: the queryable, on-chain copy of the ecosystem's
///         `FixedForceDeploymentsData` at a fixed built-in address. L2 contracts can look
///         ecosystem facts up here at runtime instead of each storing its own initialized copy,
///         and anyone can hold `dataHash()` against the bytes the L1 release pins.
interface IL2EcosystemRegistry {
    /// @notice Emitted every time the pinned ecosystem data is replaced (genesis and each
    ///         protocol upgrade).
    event EcosystemDataUpdated(bytes32 indexed dataHash);

    /// @notice Replaces the pinned ecosystem data with the release's bytes, verbatim.
    /// @param _fixedForceDeploymentsData The ABI-encoded `FixedForceDeploymentsData` the release
    ///        pins — stored as received, so `dataHash()` equals the hash of the L1-pinned bytes.
    function updateL2(bytes calldata _fixedForceDeploymentsData) external;

    /// @notice `keccak256` of the stored bytes — compare against
    ///         `keccak256(ICTMRelease.fixedForceDeploymentsData())` on L1 to verify this chain's
    ///         ecosystem data transitively from the release pin.
    function dataHash() external view returns (bytes32);

    /// @notice The whole decoded ecosystem data, exactly as pinned.
    function getFixedForceDeploymentsData() external view returns (FixedForceDeploymentsData memory);

    function l1ChainId() external view returns (uint256);

    function eraChainId() external view returns (uint256);

    function l1AssetRouter() external view returns (address);

    function aliasedL1Governance() external view returns (address);

    function aliasedChainRegistrationSender() external view returns (address);

    function zkTokenAssetId() external view returns (bytes32);
}
