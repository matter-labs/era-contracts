// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @notice The per-chain engine of the BOOTSTRAP edge — the one-time entry into the registry
///         model: the init target of the cut `RegistryBootstrapMigration` commits.
interface IBootstrapUpgrade {
    /// @notice Crosses the bootstrap edge on the diamond this contract is delegatecalled into: the
    ///         full facet reinstall derived on-chain, then the version edge, schedule and L2 plan
    ///         read from the pinned migration object, with the verifier of the genesis release the
    ///         engine pins.
    /// @param _migration The `RegistryBootstrapMigration` whose committed cut names this engine.
    /// @return The diamond-init success value.
    function upgradeFromBootstrap(address _migration) external returns (bytes32);
}
