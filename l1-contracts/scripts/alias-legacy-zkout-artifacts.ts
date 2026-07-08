import { promises as fs } from "fs";
import * as path from "path";

/**
 * Produces legacy-named copies of zksync (`zkout/`) build artifacts for external consumers that are pinned to an
 * older contract name. This does NOT declare any Solidity contract — it only duplicates an already-compiled
 * artifact under the name a downstream tool expects.
 *
 * Currently: the bootloader test infrastructure (`system-contracts/bootloader/test_infra`, pinned to a
 * `zksync-era` revision) loads the L2 interop handler bytecode from `zkout/InteropHandler.sol/InteropHandler.json`.
 * That contract was renamed to `L2InteropHandler` in this repo, so we alias the artifact under the old path.
 * Remove the corresponding entry once the pinned `zksync-era` contract loader is updated to `L2InteropHandler`.
 */
const ZKOUT_ARTIFACT_ALIASES: { from: string; to: string }[] = [
  { from: "L2InteropHandler.sol/L2InteropHandler.json", to: "InteropHandler.sol/InteropHandler.json" },
];

async function main(): Promise<void> {
  const zkoutDir = path.join(__dirname, "..", "zkout");

  for (const { from, to } of ZKOUT_ARTIFACT_ALIASES) {
    const src = path.join(zkoutDir, from);
    const dest = path.join(zkoutDir, to);

    try {
      await fs.access(src);
    } catch {
      // The zksync build did not produce the source artifact (e.g. it was skipped); nothing to alias.
      console.warn(`alias-legacy-zkout-artifacts: source artifact not found, skipping: ${from}`);
      continue;
    }

    await fs.mkdir(path.dirname(dest), { recursive: true });
    await fs.copyFile(src, dest);
    console.log(`alias-legacy-zkout-artifacts: ${from} -> ${to}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
