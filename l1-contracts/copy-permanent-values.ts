#!/usr/bin/env ts-node
/**
 * Script to copy deployment values from script-out TOML files to upgrade-envs/permanent-values/local.toml
 */

import * as fs from "fs";
import * as path from "path";
import * as toml from "toml";

// Define paths
const scriptDir = __dirname;
const scriptOutDir = path.join(scriptDir, "script-out");
const outputDeployL1 = path.join(scriptOutDir, "output-deploy-l1.toml");
const outputDeployCTM = path.join(scriptOutDir, "output-deploy-ctm.toml");
const permanentValuesOut = path.join(scriptDir, "upgrade-envs", "permanent-values", "local.toml");

// Read input TOML files
const deployL1Data = toml.parse(fs.readFileSync(outputDeployL1, "utf-8"));
const deployCTMData = toml.parse(fs.readFileSync(outputDeployCTM, "utf-8"));

// Extract values and build the output structure
const outputData = {
  era_chain_id: deployL1Data.era_chain_id,
  core_contracts: {
    bridgehub_proxy_addr: deployL1Data.deployed_addresses.bridgehub.bridgehub_proxy_addr,
  },
  ctm_contracts: {
    ctm_proxy_addr: deployCTMData.deployed_addresses.state_transition.state_transition_proxy_addr,
    rollup_da_manager: deployCTMData.deployed_addresses.l1_rollup_da_manager,
    l1_bytecodes_supplier_addr: deployCTMData.deployed_addresses.state_transition.bytecodes_supplier_addr,
  },
  permanent_contracts: {
    create2_factory_addr: deployL1Data.contracts.create2_factory_addr,
    create2_factory_salt: deployL1Data.contracts.create2_factory_salt,
  },
};

// Write the output TOML file (manually format since toml package only parses)
const outputToml = `era_chain_id = ${outputData.era_chain_id}

[core_contracts]
bridgehub_proxy_addr = "${outputData.core_contracts.bridgehub_proxy_addr}"

[ctm_contracts]
ctm_proxy_addr = "${outputData.ctm_contracts.ctm_proxy_addr}"
rollup_da_manager = "${outputData.ctm_contracts.rollup_da_manager}"
l1_bytecodes_supplier_addr = "${outputData.ctm_contracts.l1_bytecodes_supplier_addr}"

[permanent_contracts]
create2_factory_addr = "${outputData.permanent_contracts.create2_factory_addr}"
create2_factory_salt = "${outputData.permanent_contracts.create2_factory_salt}"
`;

fs.writeFileSync(permanentValuesOut, outputToml);

console.log(`✓ Successfully copied values to ${permanentValuesOut}`);
console.log(`  - era_chain_id: ${outputData.era_chain_id}`);
console.log(`  - bridgehub_proxy_addr: ${outputData.core_contracts.bridgehub_proxy_addr}`);
console.log(`  - ctm_proxy_addr: ${outputData.ctm_contracts.ctm_proxy_addr}`);
console.log(`  - create2_factory_addr: ${outputData.permanent_contracts.create2_factory_addr}`);
