// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// The canonical definitions of `L2EcosystemContract` and `ZKsyncOSUpgradeType` live in the production
// contracts tree (they key the upgrade registries); they are re-exported here so that all
// deploy-script importers keep working unchanged.
import {L2EcosystemContract, ZKsyncOSUpgradeType} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

/// @notice System contracts that have ZKsyncOS-specific implementations in l1-contracts.
///         These use EVM bytecodes (from l1-contracts/out/) for ZKsyncOS proxy upgrades.
enum ZkSyncOsSystemContract {
    L2BaseToken,
    L1Messenger,
    SystemContext,
    ContractDeployer
}
