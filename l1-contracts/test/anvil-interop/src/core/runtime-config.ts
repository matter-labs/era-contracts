import anvilConfig from "../../config/anvil-config.json";

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
 * `AnvilManager` reads when starting the synthetic L1).
 */

const l1DefaultChainId = anvilConfig.chains.find((c) => c.role === "l1")?.chainId;
if (l1DefaultChainId == null) {
  throw new Error("anvil-config.json: no chain with role=l1 — runtimeConfig cannot determine default L1 chain id");
}

export const runtimeConfig = {
  /** L1 chain id of the active anvil fork. Reset to upstream's real chain id by fork-mode harnesses. */
  l1ChainId: l1DefaultChainId,
};
