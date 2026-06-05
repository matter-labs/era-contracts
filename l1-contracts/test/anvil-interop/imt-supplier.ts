/**
 * IMT supplier CLI.
 *
 * A trusted off-chain component that reads the historical global interop-IMT roots recorded on L1
 * by {GlobalInteropIMT} and imports them into an L2 {L2GlobalInteropRootImporter}. This stands in
 * for the zkSync OS feature that would deliver the global root to L2 as an interop dependency; in
 * the demo the supplier is simply trusted (mirrors how the {L2InteropRootStorage} bootloader path
 * is mocked by an EOA).
 *
 * Usage:
 *   npx ts-node imt-supplier.ts \
 *       --l1-rpc <url> --l2-rpc <url> \
 *       --registry <l1 GlobalInteropIMT addr> --importer <l2 importer addr> \
 *       --pk <supplier private key> [--from-index <n>] [--poll <seconds>]
 *
 * Without --poll it imports all currently-recorded roots once and exits. With --poll it keeps
 * polling L1 for new history entries every <seconds> and imports them as they appear.
 */

import { Contract, providers, Wallet } from "ethers";
import { getAbi } from "./src/core/contracts";

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

function require_(flags: Record<string, string>, key: string): string {
  if (!flags[key]) throw new Error(`missing required flag --${key}`);
  return flags[key];
}

function log(msg: string): void {
  // eslint-disable-next-line no-console
  console.log(`[imt-supplier] ${msg}`);
}

/**
 * Imports every L1 history entry (from `fromIndex`) not yet present on L2.
 * @returns the next index to resume from.
 */
async function syncOnce(registry: Contract, importer: Contract, fromIndex: number): Promise<number> {
  const historyLength = (await registry.historyLength()).toNumber();
  for (let i = fromIndex; i < historyLength; i++) {
    const l1Block = (await registry.historyBlockAt(i)).toNumber();
    if (await importer.isImported(l1Block)) {
      continue;
    }
    const globalRoot: string = await registry.globalRootAtBlock(l1Block);
    const timestamp = (await registry.timestampAtBlock(l1Block)).toNumber();
    const tx = await importer.importGlobalRoot(l1Block, timestamp, globalRoot);
    await tx.wait();
    log(`imported global root for L1 block ${l1Block} (ts ${timestamp}): ${globalRoot}`);
  }
  return historyLength;
}

async function sleep(seconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, seconds * 1000));
}

async function main(): Promise<void> {
  const flags = parseFlags(process.argv.slice(2));

  const l1Provider = new providers.JsonRpcProvider(require_(flags, "l1-rpc"));
  const l2Provider = new providers.JsonRpcProvider(require_(flags, "l2-rpc"));
  const supplier = new Wallet(require_(flags, "pk"), l2Provider);

  const registry = new Contract(require_(flags, "registry"), getAbi("GlobalInteropIMT"), l1Provider);
  const importer = new Contract(require_(flags, "importer"), getAbi("L2GlobalInteropRootImporter"), supplier);

  let nextIndex = flags["from-index"] ? Number(flags["from-index"]) : 0;
  const pollSeconds = flags["poll"] ? Number(flags["poll"]) : 0;

  nextIndex = await syncOnce(registry, importer, nextIndex);
  log(`synced up to history index ${nextIndex}`);

  if (pollSeconds > 0) {
    log(`polling L1 every ${pollSeconds}s for new global roots...`);
    // eslint-disable-next-line no-constant-condition
    while (true) {
      await sleep(pollSeconds);
      nextIndex = await syncOnce(registry, importer, nextIndex);
    }
  }
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
