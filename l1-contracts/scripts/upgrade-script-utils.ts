/**
 * Shared utilities for upgrade scripts that interact with on-chain permanent-values TOML files.
 */

import * as fs from "fs";
import * as path from "path";
import * as toml from "toml";
import { ethers } from "ethers";

// ─── Paths ─────────────────────────────────────────────────────────────────

/** Directory containing per-environment permanent-values TOML files. */
export const PERMANENT_VALUES_DIR = path.join(__dirname, "../upgrade-envs/permanent-values");

/**
 * Directory where intermediate script output files are stored.
 * These files are intentionally git-ignored and are never checked in.
 */
export const SCRIPT_OUT_DIR = path.join(__dirname, "../script-out");

// ─── TOML helpers ───────────────────────────────────────────────────────────

/** Reads and parses the permanent-values TOML file for the given environment. */
export function readPermanentValues(envName: string): Record<string, unknown> {
  const file = path.join(PERMANENT_VALUES_DIR, `${envName}.toml`);
  if (!fs.existsSync(file)) {
    throw new Error(`Permanent values file not found: ${file}`);
  }
  return toml.parse(fs.readFileSync(file, "utf-8"));
}

/** Returns the bridgehub proxy address for the given environment (checksummed). */
export function getBridgehubAddress(envName: string): string {
  const pv = readPermanentValues(envName);
  const addr = (pv as { core_contracts?: { bridgehub_proxy_addr?: string } }).core_contracts
    ?.bridgehub_proxy_addr;
  if (!addr) {
    throw new Error(
      `core_contracts.bridgehub_proxy_addr not found in ${envName}.toml`
    );
  }
  return ethers.utils.getAddress(addr);
}

/** Returns the legacy gateway chain ID for the given environment (0 if not configured). */
export function getLegacyGatewayChainId(envName: string): number {
  const pv = readPermanentValues(envName);
  const chainId = (pv as { legacy_gateway?: { chain_id?: number } }).legacy_gateway?.chain_id;
  return chainId ?? 0;
}

// ─── ABI helpers ────────────────────────────────────────────────────────────

/**
 * Reads an ABI from a Foundry output JSON file.
 * These files are produced by `forge build` and are NOT committed to the repository.
 * Load lazily inside commands that require them (never at module load time) so that
 * commands that only read committed files (e.g. `write`) continue to work on a clean checkout.
 */
export function loadAbiFromFoundryOutput(relativePath: string): ethers.ContractInterface {
  const fullPath = path.join(__dirname, relativePath);
  if (!fs.existsSync(fullPath)) {
    throw new Error(
      `Foundry output file not found: ${fullPath}\n` +
        "Run `forge build` in l1-contracts/ to generate ABI files."
    );
  }
  return JSON.parse(fs.readFileSync(fullPath, "utf-8")).abi;
}
