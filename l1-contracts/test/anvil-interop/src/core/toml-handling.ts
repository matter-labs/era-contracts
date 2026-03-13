import * as path from "path";
import { parseForgeScriptOutput, saveTomlConfig } from "./utils";

/**
 * Merge L1 core output and CTM output into a single TOML file for the Forge script.
 *
 * _GatewayPreparationForTests.initializeConfig() reads from CTM_OUTPUT and expects:
 * - $.deployed_addresses.bridgehub.bridgehub_proxy_addr (from L1 core output)
 * - $.deployed_addresses.bridgehub.ctm_deployment_tracker_proxy_addr (from L1 core output)
 * - $.deployed_addresses.bridges.shared_bridge_proxy_addr (in both)
 * - $.deployed_addresses.state_transition.state_transition_proxy_addr (from CTM output)
 */
export function prepareMergedToml(outputDir: string): void {
  const l1CorePath = path.join(outputDir, "l1-core-output.toml");
  const ctmPath = path.join(outputDir, "ctm-output.toml");

  const l1Core = parseForgeScriptOutput(l1CorePath);
  const ctm = parseForgeScriptOutput(ctmPath);

  // Deep merge: CTM output takes precedence at leaf level, but we need
  // the bridgehub section from L1 core output (CTM output doesn't have it)
  const merged = deepMerge(ctm, l1Core);

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
