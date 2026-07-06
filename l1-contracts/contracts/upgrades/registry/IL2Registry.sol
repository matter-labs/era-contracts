// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title L2-side upgrade registry.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A generated, constants-in-bytecode registry deployed on every L2 chain as the first
///         entry of the protocol upgrade transaction's force-deployment list, at a fixed
///         predeploy address every L2 system contract can hard-code.
/// @notice What it provides that predeploy constants cannot: L1 addresses that L2 contracts
///         reference (today compiled into L2 bytecode or threaded through genesis init data as
///         per-ecosystem values, forcing per-ecosystem L2 bytecode). Reading them from this
///         registry at runtime gives ONE audited L2 bytecode per VM — the only per-ecosystem L2
///         artifact left is the generated registry itself, whose bytecode hash is pinned by the
///         L1 CTM registry (`l2BytecodeHash`), so verifying L1 transitively verifies L2.
/// @dev Implementations are generated per (ecosystem, protocol version). They MUST NOT declare a
///      constructor or immutables: L2 contracts are deployed within the ZKsync OS environment,
///      which does not support constructors (see repo guidelines) — every value is a `constant`.
interface IL2Registry {
    /// @notice The packed SemVer protocol version this registry was deployed with.
    function protocolVersion() external view returns (uint256);

    /// @notice The chain id of the L1 this ecosystem settles on.
    function l1ChainId() external view returns (uint256);

    /// @notice The Era chain id of this ecosystem.
    function eraChainId() external view returns (uint256);

    /// @notice The L1 Bridgehub proxy address.
    function l1Bridgehub() external view returns (address);

    /// @notice The L1 AssetRouter proxy address.
    function l1AssetRouter() external view returns (address);

    /// @notice The L1 Nullifier proxy address.
    function l1Nullifier() external view returns (address);

    /// @notice The L1 NativeTokenVault proxy address.
    function l1NativeTokenVault() external view returns (address);
}
