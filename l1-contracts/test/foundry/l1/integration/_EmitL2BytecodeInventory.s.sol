// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {CoreOnGatewayHelper} from "deploy-scripts/ecosystem/CoreOnGatewayHelper.sol";
import {SystemContractsProcessing} from "deploy-scripts/upgrade/SystemContractsProcessing.s.sol";
import {L2EcosystemContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

/// @notice Emits the L2 inventory a CTM prepare builds from the CURRENT artifacts — the release's
///         enum-indexed L2 bytecode table and the factory dependencies the prepare publishes — as
///         JSON, for the anvil-interop registry harness. Its bootstrap release is built from this
///         very inventory, so the harness and the production prepare share one code path for the
///         table instead of a TypeScript mirror of it.
contract EmitL2BytecodeInventory is Script {
    function run(string memory _outputPath) external {
        bytes[] memory rows = SystemContractsProcessing.buildL2BytecodeInfoTable();
        bytes[] memory factoryDeps = CoreOnGatewayHelper.getFullListOfFactoryDependencies(new L2EcosystemContract[](0));
        vm.serializeBytes("inventory", "rows", rows);
        string memory json = vm.serializeBytes("inventory", "factoryDeps", factoryDeps);
        vm.writeJson(json, _outputPath);
    }
}
