import * as fs from "fs";
import * as path from "path";

/**
 * Single mutable knob bag for harness-runtime values that aren't known at module
 * load time. The synthetic-state harness leaves the defaults; the fork harness
 * probes the upstream RPC at startup and writes back into this object before
 * any callsite reads it. Exporting a plain object (rather than getter/setter
 * pairs) keeps reads at the call site as `runtimeConfig.l1ChainId` with no
 * indirection layer.
 *
 * Defaults are sourced from `config/anvil-config.json` so the synthetic
 * harness's L1 chain id has a single source of truth (the same file
 * `AnvilManager` reads when starting the synthetic L1). We read the JSON
 * via `fs` rather than a TS `import` because the harness is loaded under
 * multiple ts-node configurations (hardhat's vs the standalone runners) and
 * the import resolver disagrees on the JSON default-export shape between
 * them.
 */

interface AnvilChainEntry {
  chainId: number;
  role: string;
}

const anvilConfigPath = path.resolve(__dirname, "../../config/anvil-config.json");
const anvilConfig = JSON.parse(fs.readFileSync(anvilConfigPath, "utf-8")) as { chains: AnvilChainEntry[] };
const l1DefaultChainId = anvilConfig.chains.find((c) => c.role === "l1")?.chainId;
if (l1DefaultChainId == null) {
  throw new Error("anvil-config.json: no chain with role=l1 — runtimeConfig cannot determine default L1 chain id");
}

export const runtimeConfig = {
  /** L1 chain id of the active anvil fork. Reset to upstream's real chain id by fork-mode harnesses. */
  l1ChainId: l1DefaultChainId,
};
