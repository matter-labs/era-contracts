import * as fs from "fs";
import { join, relative } from "path";

// The current release: the one `l1-contracts/upgrade-envs/v<major>.<minor>.<patch>-<name>/` dir of the version in
// `configs/genesis/zksync-os/latest.json`, the same one protocol-ops resolves (`current_release` in
// protocol-ops/src/common/forge/scripts/mod.rs). Run directly, it prints that dir's name:
//
//   yarn ts-node scripts/current-release.ts

const ROOT = join(__dirname, "..");
export const GENESIS_PATH = join(ROOT, "configs/genesis/zksync-os/latest.json");
export const UPGRADE_ENVS_DIR = join(ROOT, "l1-contracts/upgrade-envs");

export type SemVer = { major: number; minor: number; patch: number };

export function versionString(version: SemVer): string {
  return `v${version.major}.${version.minor}.${version.patch}`;
}

export function genesisVersion(): SemVer {
  const { major, minor, patch } = JSON.parse(fs.readFileSync(GENESIS_PATH, "utf-8")).protocol_semantic_version ?? {};
  if (![major, minor, patch].every(Number.isInteger)) {
    throw new Error(`no protocol_semantic_version in ${GENESIS_PATH}`);
  }
  return { major, minor, patch };
}

/** The name of `version`'s upgrade-env dir; there must be exactly one. */
export function releaseEnvDir(version: SemVer): string {
  const prefix = `${versionString(version)}-`;
  const dirs = fs
    .readdirSync(UPGRADE_ENVS_DIR, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith(prefix))
    .map((entry) => entry.name);
  if (dirs.length !== 1) {
    throw new Error(
      `genesis is at ${versionString(version)}, so ${relative(ROOT, UPGRADE_ENVS_DIR)} must hold exactly one ` +
        `${prefix}<name> directory; found ${JSON.stringify(dirs)}`
    );
  }
  return dirs[0];
}

if (require.main === module) {
  console.log(releaseEnvDir(genesisVersion()));
}
