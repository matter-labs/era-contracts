import * as path from "path";
import { parseForgeScriptOutput, saveTomlConfig } from "./utils";
import {
  ANVIL_INTEROP_CTM_DEPLOYMENT_CONFIG_RELATIVE,
  ANVIL_INTEROP_GATEWAY_VOTE_CONFIG_RELATIVE,
  ANVIL_INTEROP_GATEWAY_VOTE_OUTPUT_RELATIVE,
} from "./paths";
import { ANVIL_DEFAULT_ACCOUNT_ADDR } from "./const";

/**
 * Merge L1 core output and CTM output into a single TOML file for the Forge script.
 *
 * GatewayPreparationForTests.initializeConfig() reads from CTM_OUTPUT and expects:
 * - $.deployed_addresses.bridgehub.bridgehub_proxy_addr (from L1 core output)
 * - $.deployed_addresses.bridgehub.ctm_deployment_tracker_proxy_addr (from L1 core output)
 * - $.deployed_addresses.bridges.shared_bridge_proxy_addr (in both)
 * - $.deployed_addresses.state_transition.state_transition_proxy_addr (from CTM output)
 * - $.contracts_config.diamond_cut_data before gateway vote output is merged
 */
export function prepareMergedToml(outputDir: string): void {
  const l1CorePath = path.join(outputDir, "l1-core-output.toml");
  const ctmPath = path.join(outputDir, "ctm-output.toml");

  const l1Core = parseForgeScriptOutput(l1CorePath);
  const ctm = parseForgeScriptOutput(ctmPath);

  // Deep merge: CTM output takes precedence at leaf level, but we need
  // the bridgehub section from L1 core output (CTM output doesn't have it)
  const merged = deepMerge(ctm, l1Core);
  const contractsConfig = asRecord(merged.contracts_config);
  if (typeof contractsConfig?.diamond_cut_data !== "string") {
    throw new Error("Missing contracts_config.diamond_cut_data in CTM output; cannot prepare gateway merged TOML");
  }

  const mergedPath = path.join(outputDir, "gateway-merged-output.toml");
  saveTomlConfig(mergedPath, merged);
  console.log(`   Merged TOML written to ${mergedPath}`);
}

/**
 * Create gateway chain config TOML with chain.chain_chain_id.
 */
export function prepareGatewayChainConfig(outputDir: string, gatewayChainId: number): void {
  const configPath = path.join(outputDir, "gateway-chain-config.toml");
  saveTomlConfig(configPath, {
    chain: {
      chain_chain_id: gatewayChainId,
    },
  });
  console.log(`   Gateway chain config written to ${configPath}`);
}

/**
 * Create the GatewayVotePreparation config used to deploy gateway-side CTM contracts.
 */
export function prepareGatewayVoteConfig(outputDir: string, gatewayChainId: number): void {
  const ctmConfigPath = resolveInteropPath(outputDir, ANVIL_INTEROP_CTM_DEPLOYMENT_CONFIG_RELATIVE);
  const gatewayVoteConfigPath = resolveInteropPath(outputDir, ANVIL_INTEROP_GATEWAY_VOTE_CONFIG_RELATIVE);
  const ctmConfig = parseForgeScriptOutput(ctmConfigPath);
  const contracts = asRecord(ctmConfig.contracts);

  saveTomlConfig(gatewayVoteConfigPath, {
    force_deployments_data: readTomlString(contracts, "force_deployments_data"),
    gateway_chain_id: gatewayChainId,
    gateway_settlement_fee: 0,
    is_zk_sync_os: readTomlBoolean(ctmConfig, "is_zk_sync_os"),
    owner_address: readTomlString(ctmConfig, "owner_address"),
    refund_recipient: ANVIL_DEFAULT_ACCOUNT_ADDR,
    support_l2_legacy_shared_bridge_test: readTomlBoolean(ctmConfig, "support_l2_legacy_shared_bridge_test"),
    testnet_verifier: readTomlBoolean(ctmConfig, "testnet_verifier"),
    zk_token_asset_id: readTomlString(ctmConfig, "zk_token_asset_id"),
    contracts: {
      create2_factory_addr: readTomlString(contracts, "create2_factory_addr"),
      create2_factory_salt: readTomlString(contracts, "create2_factory_salt"),
      governance_min_delay: readTomlNumber(contracts, "governance_min_delay"),
      governance_security_council_address: readTomlString(contracts, "governance_security_council_address"),
      validator_timelock_execution_delay: readTomlNumber(contracts, "validator_timelock_execution_delay"),
    },
  });

  console.log(`   Gateway vote config written to ${gatewayVoteConfigPath}`);
}

/**
 * Merge gateway CTM deployment output into the gateway harness TOML.
 */
export function mergeGatewayVoteOutput(outputDir: string): void {
  const mergedPath = path.join(outputDir, "gateway-merged-output.toml");
  const gatewayVotePath = resolveInteropPath(outputDir, ANVIL_INTEROP_GATEWAY_VOTE_OUTPUT_RELATIVE);

  const merged = parseForgeScriptOutput(mergedPath);
  const gatewayVote = parseForgeScriptOutput(gatewayVotePath);
  const gatewayDiamondCutData = gatewayVote.diamond_cut_data;

  if (typeof gatewayDiamondCutData !== "string") {
    throw new Error("Missing diamond_cut_data in gateway vote output; cannot finalize gateway merged TOML");
  }

  for (const [key, value] of Object.entries(gatewayVote)) {
    merged[key] = value;
  }

  saveTomlConfig(mergedPath, merged);
  console.log(`   Gateway vote output merged into ${mergedPath}`);
}

/**
 * Deep merge two objects. `a` values override `b` values at leaf level.
 * Sub-objects are recursively merged.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function deepMerge(a: Record<string, any>, b: Record<string, any>): Record<string, any> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const result: Record<string, any> = { ...b };
  for (const key of Object.keys(a)) {
    if (
      a[key] &&
      typeof a[key] === "object" &&
      !Array.isArray(a[key]) &&
      b[key] &&
      typeof b[key] === "object" &&
      !Array.isArray(b[key])
    ) {
      result[key] = deepMerge(a[key], b[key]);
    } else {
      result[key] = a[key];
    }
  }
  return result;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

function resolveInteropPath(outputDir: string, relativePathFromL1Contracts: string): string {
  return path.resolve(outputDir, "../../..", relativePathFromL1Contracts.slice(1));
}

function readTomlString(source: Record<string, unknown> | undefined, key: string): string {
  const value = source?.[key];
  if (typeof value !== "string") {
    throw new Error(`Missing string TOML key: ${key}`);
  }
  return value;
}

function readTomlBoolean(source: Record<string, unknown> | undefined, key: string): boolean {
  const value = source?.[key];
  if (typeof value !== "boolean") {
    throw new Error(`Missing boolean TOML key: ${key}`);
  }
  return value;
}

function readTomlNumber(source: Record<string, unknown> | undefined, key: string): number {
  const value = source?.[key];
  if (typeof value !== "number") {
    throw new Error(`Missing numeric TOML key: ${key}`);
  }
  return value;
}
