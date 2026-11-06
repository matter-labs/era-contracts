import * as fs from "fs";
import * as path from "path";

export interface ForkConfig {
  l1ForkUrl: string;
  l1ForkBlock?: number;
  bridgehubAddress: string;
  /** Map from L2 chain ID → RPC URL. */
  l2RpcByChainId: Map<number, string>;
  /** Specific chain IDs to test. If empty, discovery picks the first 2 zkOS chains. */
  chainIdFilter: number[];
}

/**
 * Resolve an optional numeric env var.
 */
function readOptionalNumber(name: string): number | undefined {
  const raw = process.env[name];
  if (!raw || raw.trim().length === 0) return undefined;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) {
    throw new Error(`Env var ${name} is not a valid number: ${raw}`);
  }
  return parsed;
}

/**
 * Parse a comma-separated list of chain IDs from an env var.
 */
function readChainIdList(name: string): number[] {
  const raw = process.env[name];
  if (!raw || raw.trim().length === 0) return [];
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map((s) => {
      const n = Number(s);
      if (!Number.isFinite(n)) {
        throw new Error(`Env var ${name} contains non-numeric chain ID: ${s}`);
      }
      return n;
    });
}

/**
 * Load the per-chain L2 RPC map.
 *
 * Sources (in order, later overrides earlier):
 *   1. config/fork-l2-rpcs.json (optional, gitignored) — { "<chainId>": "<url>" }
 *   2. Env vars L2_FORK_URL_<chainId> for any explicit overrides
 */
function loadL2RpcMap(configDir: string): Map<number, string> {
  const result = new Map<number, string>();

  const configPath = path.join(configDir, "fork-l2-rpcs.json");
  if (fs.existsSync(configPath)) {
    const raw = fs.readFileSync(configPath, "utf-8").trim();
    if (raw.length > 0) {
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch (err) {
        // The file used to hold a plain-text URL list and may still be that
        // way locally. Don't hard-fail loading the harness config — log + skip.
        console.warn(
          `[fork-config] ${configPath} is not valid JSON, ignoring: ${err instanceof Error ? err.message : String(err)}`
        );
        return result;
      }
      if (parsed === null || typeof parsed !== "object") {
        throw new Error(`${configPath}: expected a JSON object { "<chainId>": "<url>" }`);
      }
      for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
        const chainId = Number(key);
        if (!Number.isFinite(chainId)) {
          throw new Error(`${configPath}: non-numeric chain ID key: ${key}`);
        }
        if (typeof value !== "string") {
          throw new Error(`${configPath}: value for chain ${chainId} must be a string URL`);
        }
        result.set(chainId, value);
      }
    }
  }

  for (const envKey of Object.keys(process.env)) {
    const match = /^L2_FORK_URL_(\d+)$/.exec(envKey);
    if (!match) continue;
    const chainId = Number(match[1]);
    const url = process.env[envKey];
    if (url && url.trim().length > 0) {
      result.set(chainId, url);
    }
  }

  return result;
}

/**
 * Load the full fork-mode config from env vars + config/fork-l2-rpcs.json.
 *
 * Required env vars:
 *   L1_FORK_URL         — upstream L1 RPC to fork
 *   BRIDGEHUB_ADDRESS   — L1 Bridgehub proxy on the forked L1
 *
 * Optional env vars:
 *   L1_FORK_BLOCK       — pin the L1 fork to a specific block
 *   FORK_CHAIN_IDS      — comma-separated list (e.g. "270,271") to explicitly pick test chains
 */
export function loadForkConfig(configDir: string): ForkConfig {
  const l1ForkUrl = process.env.L1_FORK_URL;
  if (!l1ForkUrl || l1ForkUrl.trim().length === 0) {
    throw new Error("L1_FORK_URL env var is required");
  }
  const bridgehubAddress = process.env.BRIDGEHUB_ADDRESS;
  if (!bridgehubAddress || bridgehubAddress.trim().length === 0) {
    throw new Error("BRIDGEHUB_ADDRESS env var is required");
  }

  return {
    l1ForkUrl,
    l1ForkBlock: readOptionalNumber("L1_FORK_BLOCK"),
    bridgehubAddress,
    l2RpcByChainId: loadL2RpcMap(configDir),
    chainIdFilter: readChainIdList("FORK_CHAIN_IDS"),
  };
}
