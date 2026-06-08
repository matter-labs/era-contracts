/**
 * Atomic-interop root relayer.
 *
 * A trusted demo daemon that, each cycle:
 *   A. EXPOSE — reads every configured L2's current interop IMT root and submits it to the L1
 *      `GlobalInteropIMT` registry (via the temporary global-submitter stub), and
 *   B. SUPPLY — imports the resulting historical global roots into every L2's
 *      `L2GlobalInteropRootImporter`.
 *
 * It is the demo stand-in for the production path where each chain's `Executor` submits its own root
 * and the bootloader delivers the global root to L2. A single private key is used for all chains.
 *
 * Prerequisites (one-time, by the registry owner / each importer's supplier):
 *   - the relayer key must be authorized via `GlobalInteropIMT.setGlobalSubmitter(relayer, true)`;
 *   - the relayer key must be each importer's `supplier` (set at `initialize`).
 *
 * Config: a JSON file (`--config <path>`) holding the chain list (with per-chain addresses); the
 * connection params can be set there or overridden by flags. Shape:
 *   {
 *     "l1Rpc": "http://localhost:8545",
 *     "registry": "0x<GlobalInteropIMT>",
 *     "privateKey": "0x...",
 *     "chains": [
 *       { "chainId": 271, "rpc": "http://localhost:9545", "tree": "0x<tree>", "importer": "0x<importer>" }
 *     ]
 *   }
 *
 * Usage:
 *   npx ts-node atomic-root-relayer.ts --config relayer.json
 *   npx ts-node atomic-root-relayer.ts --config relayer.json \
 *       --l1-rpc <url> --registry 0x.. --pk 0x.. --poll 5
 *
 * `--l1-rpc`, `--registry`, `--pk`, `--poll <seconds>` override the config. Without `--poll` it runs
 * a single cycle and exits.
 */

import * as fs from "fs";
import { Contract, providers, Wallet } from "ethers";
import { getAbi } from "./src/core/contracts";
import { commitmentTree, globalRegistry } from "./src/helpers/imt-engine-lib";

interface ChainCfg {
  chainId: number;
  rpc: string;
  tree: string;
  importer: string;
}
interface RelayerConfig {
  l1Rpc: string;
  registry: string;
  privateKey: string;
  chains: ChainCfg[];
}

function parseFlags(argv: string[]): Record<string, string> {
  const flags: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const val = i + 1 < argv.length && !argv[i + 1].startsWith("--") ? argv[++i] : "true";
      flags[key] = val;
    }
  }
  return flags;
}

function log(msg: string): void {
  // eslint-disable-next-line no-console
  console.log(`[relayer] ${msg}`);
}

function loadConfig(flags: Record<string, string>): RelayerConfig {
  const base: Partial<RelayerConfig> = flags["config"]
    ? (JSON.parse(fs.readFileSync(flags["config"], "utf8")) as Partial<RelayerConfig>)
    : {};
  const cfg: RelayerConfig = {
    l1Rpc: flags["l1-rpc"] ?? base.l1Rpc ?? "",
    registry: flags["registry"] ?? base.registry ?? "",
    privateKey: flags["pk"] ?? base.privateKey ?? "",
    chains: base.chains ?? [],
  };
  if (!cfg.l1Rpc) throw new Error("missing l1Rpc (--l1-rpc or config.l1Rpc)");
  if (!cfg.registry) throw new Error("missing registry (--registry or config.registry)");
  if (!cfg.privateKey) throw new Error("missing privateKey (--pk or config.privateKey)");
  if (cfg.chains.length === 0) throw new Error("config.chains is empty; provide a --config with the chain list");
  return cfg;
}

function importerContract(addr: string, signerOrProvider: Wallet | providers.Provider): Contract {
  return new Contract(addr, getAbi("L2GlobalInteropRootImporter"), signerOrProvider);
}

/**
 * Phase A — for each chain whose IMT root changed since its last submission, submit the new root to
 * the L1 registry. Returns true if anything was submitted (the global root advanced).
 */
async function expose(cfg: RelayerConfig, l1Wallet: Wallet): Promise<boolean> {
  const registry = globalRegistry(cfg.registry, l1Wallet);
  let advanced = false;
  for (const chain of cfg.chains) {
    const l2Provider = new providers.JsonRpcProvider(chain.rpc);
    const root: string = await commitmentTree(chain.tree, l2Provider).root();
    const known: string = await registry.chainRootOf(chain.chainId);
    if (root === known) {
      continue; // nothing new on this chain
    }
    const nextBatch = (await registry.currentBatchNumber(chain.chainId)).add(1);
    const tx = await registry.submitChainRoot(chain.chainId, nextBatch, root);
    await tx.wait();
    advanced = true;
    log(`exposed chain ${chain.chainId} root ${root} as batch ${nextBatch.toString()} (tx ${tx.hash})`);
  }
  return advanced;
}

/** Phase B — import every recorded L1 global root not yet present on each chain's importer. */
async function supply(cfg: RelayerConfig, l1Provider: providers.Provider): Promise<void> {
  const registry = globalRegistry(cfg.registry, l1Provider);
  const historyLength = (await registry.historyLength()).toNumber();
  if (historyLength === 0) {
    return;
  }
  for (const chain of cfg.chains) {
    const l2Wallet = new Wallet(cfg.privateKey, new providers.JsonRpcProvider(chain.rpc));
    const importer = importerContract(chain.importer, l2Wallet);
    for (let i = 0; i < historyLength; i++) {
      const l1Block = (await registry.historyBlockAt(i)).toNumber();
      if (await importer.isImported(l1Block)) {
        continue;
      }
      const globalRoot: string = await registry.globalRootAtBlock(l1Block);
      const timestamp = (await registry.timestampAtBlock(l1Block)).toNumber();
      const tx = await importer.importGlobalRoot(l1Block, timestamp, globalRoot);
      await tx.wait();
      log(`imported global root ${globalRoot} (L1 block ${l1Block}) into chain ${chain.chainId}`);
    }
  }
}

async function relayOnce(cfg: RelayerConfig): Promise<void> {
  const l1Provider = new providers.JsonRpcProvider(cfg.l1Rpc);
  const l1Wallet = new Wallet(cfg.privateKey, l1Provider);
  await expose(cfg, l1Wallet);
  await supply(cfg, l1Provider);
}

async function sleep(seconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, seconds * 1000));
}

async function main(): Promise<void> {
  const flags = parseFlags(process.argv.slice(2));
  const cfg = loadConfig(flags);
  const relayer = new Wallet(cfg.privateKey).address;
  log(`relaying ${cfg.chains.length} chain(s) as ${relayer} -> registry ${cfg.registry}`);

  await relayOnce(cfg);
  log("cycle complete");

  const pollSeconds = flags["poll"] ? Number(flags["poll"]) : 0;
  if (pollSeconds > 0) {
    log(`polling every ${pollSeconds}s...`);
    // eslint-disable-next-line no-constant-condition
    while (true) {
      await sleep(pollSeconds);
      await relayOnce(cfg);
    }
  }
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
