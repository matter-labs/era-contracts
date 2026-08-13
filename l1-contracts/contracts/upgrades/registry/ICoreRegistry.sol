// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @notice One ecosystem contract's upgrade row: a SOURCE-CHECKED edge, not just a target.
/// @dev Scope: implementation swaps only — every row executes as a plain `ProxyAdmin.upgrade`.
///      A proxy needing an initializer call as part of its upgrade is deliberately NOT expressible
///      here; expressing it would mean pinning arbitrary calldata, which is a different (and much
///      wider) review surface than "this proxy moves from this implementation to that one". Such
///      an upgrade belongs in a version-specific script until a pinned-initializer row shape is
///      designed and audited on its own terms.
/// @param proxy The ecosystem proxy this row upgrades.
/// @param expectedOldImpl The implementation the proxy must currently point at for this row to
///        apply. This is the replay guard: after a later registry moves the proxy on, replaying
///        this registry cannot silently downgrade it — the source no longer matches.
/// @param implNew The implementation the proxy points at afterwards.
/// @param implNewCodehash The MANDATORY `EXTCODEHASH` pin of `implNew`, inline beside the address
///        it protects.
struct EcosystemContractRow {
    address proxy;
    address expectedOldImpl;
    address implNew;
    bytes32 implNewCodehash;
}

/// @title Core (ecosystem-wide) upgrade registry.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lookup surface of a storage-backed, write-once registry that pins every
///         ecosystem-wide L1 contract row for one protocol upgrade, as a `fromState -> toState`
///         edge (see {EcosystemContractRow}).
/// @dev The registry is initialized once from an audited manifest; `manifestHash` commits to the
///      pinned values and each `implNew` carries an inline `EXTCODEHASH` pin verified by
///      `validate()` / `verifyAll()`. Version-schedule identity is owned by {ICTMTransition},
///      not pinned here.
interface ICoreRegistry {
    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment to every pinned value,
    ///         and the key under which the deploying factory attests this instance.
    function manifestHash() external view returns (bytes32);

    /// @notice Every ecosystem contract participating in this upgrade, as complete typed rows —
    ///         one call, no per-key rescans. Consumers iterate these directly.
    function ecosystemRows() external view returns (EcosystemContractRow[] memory);

    /// @notice Walks every pinned implementation and compares its `EXTCODEHASH` against the hash
    ///         pinned at generation time. Anyone can call this to check that deployed bytecode
    ///         matches what was audited. Each registry (core + per-CTM) is verified independently.
    function verifyAll() external view returns (bool);

    /// @notice The reverting counterpart of {verifyAll}, used on execution paths.
    function validate() external view;
}
