import * as path from "path";
import { ethers } from "ethers";
import { ENV_ANVIL_PORTS, V31_UPGRADE_NAME } from "./constants";
import { L1_CONTRACTS_DIR, readToml, requireFile, requireTomlString } from "./file-system";

export type UpgradeEnvironmentName = keyof typeof ENV_ANVIL_PORTS;

export interface UpgradeEnvironment {
  name: UpgradeEnvironmentName;
  outputDirectory: string;
  bridgehubAddress: string;
  zkAssetId: string;
  hasGateway: boolean;
}

export function parseUpgradeEnvironment(environment: string): UpgradeEnvironmentName {
  if (!Object.prototype.hasOwnProperty.call(ENV_ANVIL_PORTS, environment)) {
    throw new Error(
      `Unknown env '${environment}' (expected: ${Object.keys(ENV_ANVIL_PORTS).join(" | ")}). ` +
        "Add a dedicated port in upgrade-bundle/constants.ts."
    );
  }
  return environment as UpgradeEnvironmentName;
}

export function anvilPort(environment: UpgradeEnvironmentName): number {
  return ENV_ANVIL_PORTS[environment];
}

export function loadUpgradeEnvironment(name: UpgradeEnvironmentName): UpgradeEnvironment {
  const outputDirectory = path.join(L1_CONTRACTS_DIR, "upgrade-envs", V31_UPGRADE_NAME, "output", name);
  const permanentValuesPath = path.join(L1_CONTRACTS_DIR, "upgrade-envs/permanent-values", `${name}.toml`);
  const inputPath = path.join(L1_CONTRACTS_DIR, "upgrade-envs", V31_UPGRADE_NAME, `${name}.toml`);
  requireFile(permanentValuesPath, `config for env '${name}'`);
  requireFile(inputPath, `config for env '${name}'`);

  const permanentValues = readToml(permanentValuesPath);
  const input = readToml(inputPath);
  const bridgehubAddress = ethers.utils.getAddress(
    requireTomlString(input, "contracts.bridgehub_proxy_address", inputPath)
  );
  const zkAssetId = requireTomlString(permanentValues, "zk_token_asset_id", permanentValuesPath);
  if (!ethers.utils.isHexString(zkAssetId, 32)) {
    throw new Error(`zk_token_asset_id in ${permanentValuesPath} must be 32 bytes`);
  }

  return {
    name,
    outputDirectory,
    bridgehubAddress,
    zkAssetId,
    hasGateway: permanentValues.new_gateway !== undefined,
  };
}
