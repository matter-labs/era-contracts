import * as fs from "fs";
import { join, relative } from "path";

// Starts a new protocol release on the current branch: moves every place that names "the current release"
// to the next minor version, so the default upgrade (protocol-ops' `upgrade-prepare-all` defaults) and the
// upgrade tests target it. Usage:
//
//   yarn new-release <name> [--dry-run]      e.g. `yarn new-release chain-config`
//
// What it changes:
//   1. `configs/genesis/zksync-os/latest.json` `protocol_semantic_version`: minor + 1, patch 0. The default
//      upgrade scripts read their target version from it, and the upgrade tests assert it.
//   2. `l1-contracts/upgrade-envs/v0.<minor>.0-<name>/local.toml`: the local upgrade input, copied from the
//      current release's with its version fields moved.
//   3. protocol-ops' current upgrade-env dir (`current_upgrade_env_dir!` in
//      `protocol-ops/src/common/forge/scripts/mod.rs`): the prepare defaults and `--env` resolution follow it.
//   4. `l1-contracts/test/anvil-interop/config/anvil-config.json`: the outgoing `stateVersion` becomes the
//      `upgradeSourceStateVersion` the upgrade test starts from, `stateVersion` moves to the new release,
//      and the previous source chain states are deleted.
//
// What it leaves to you (printed at the end): regenerating the new release's chain states, per-environment
// upgrade inputs, and any release-specific upgrade scripts.

const ROOT = join(__dirname, "..");
const GENESIS_PATH = join(ROOT, "configs/genesis/zksync-os/latest.json");
const UPGRADE_ENVS_DIR = join(ROOT, "l1-contracts/upgrade-envs");
const PROTOCOL_OPS_SCRIPTS_PATH = join(ROOT, "protocol-ops/src/common/forge/scripts/mod.rs");
const ANVIL_CONFIG_PATH = join(ROOT, "l1-contracts/test/anvil-interop/config/anvil-config.json");
const CHAIN_STATES_DIR = join(ROOT, "l1-contracts/test/anvil-interop/chain-states");

// Same packing as `SemVer.packSemVer`.
const SEMVER_MINOR_OFFSET = 32n;
const SEMVER_MAJOR_OFFSET = 64n;

const RELEASE_NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const VERSION_BLOCK_RE =
  /("protocol_semantic_version":\s*\{\s*"major":\s*)(\d+)(,\s*"minor":\s*)(\d+)(,\s*"patch":\s*)(\d+)/;
const ENV_DIR_MACRO_RE = /(macro_rules! current_upgrade_env_dir \{\s*\(\) => \{\s*")(upgrade-envs\/[^"]+)(")/;

type SemVer = { major: number; minor: number; patch: number };

function packSemVer(version: SemVer): string {
  const packed =
    (BigInt(version.major) << SEMVER_MAJOR_OFFSET) |
    (BigInt(version.minor) << SEMVER_MINOR_OFFSET) |
    BigInt(version.patch);
  return `0x${packed.toString(16)}`;
}

function versionString(version: SemVer): string {
  return `v${version.major}.${version.minor}.${version.patch}`;
}

function setTomlBareValue(contents: string, key: string, value: string): string {
  const pattern = new RegExp(`^(${key}\\s*=\\s*)[^#\\n]*?(\\s*(#.*)?)$`, "m");
  if (!pattern.test(contents)) {
    throw new Error(`local.toml has no \`${key}\` to move`);
  }
  return contents.replace(pattern, `$1${value}$2`);
}

function main(): void {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const positional = args.filter((arg) => !arg.startsWith("--"));
  if (positional.length !== 1 || !RELEASE_NAME_RE.test(positional[0])) {
    throw new Error("usage: yarn new-release <kebab-case-name> [--dry-run]");
  }
  const name = positional[0];
  const writes: Array<() => void> = [];
  const changed: string[] = [];
  const write = (path: string, contents: string) => {
    changed.push(`write  ${relative(ROOT, path)}`);
    writes.push(() => {
      fs.mkdirSync(join(path, ".."), { recursive: true });
      fs.writeFileSync(path, contents);
    });
  };

  // 1. Genesis version.
  const genesis = fs.readFileSync(GENESIS_PATH, "utf-8");
  const versionMatch = genesis.match(VERSION_BLOCK_RE);
  if (!versionMatch) {
    throw new Error(`no protocol_semantic_version in ${GENESIS_PATH}`);
  }
  const current: SemVer = {
    major: Number(versionMatch[2]),
    minor: Number(versionMatch[4]),
    patch: Number(versionMatch[6]),
  };
  const next: SemVer = { major: current.major, minor: current.minor + 1, patch: 0 };
  write(GENESIS_PATH, genesis.replace(VERSION_BLOCK_RE, `$1${next.major}$3${next.minor}$5${next.patch}`));

  // 2. Local upgrade input, from the current release's.
  const scripts = fs.readFileSync(PROTOCOL_OPS_SCRIPTS_PATH, "utf-8");
  const envDirMatch = scripts.match(ENV_DIR_MACRO_RE);
  if (!envDirMatch) {
    throw new Error(`no current_upgrade_env_dir! macro in ${PROTOCOL_OPS_SCRIPTS_PATH}`);
  }
  const currentEnvDir = envDirMatch[2];
  const nextEnvDir = `upgrade-envs/${versionString(next)}-${name}`;
  const nextEnvDirAbs = join(UPGRADE_ENVS_DIR, nextEnvDir.replace("upgrade-envs/", ""));
  if (fs.existsSync(nextEnvDirAbs)) {
    throw new Error(`${relative(ROOT, nextEnvDirAbs)} already exists`);
  }
  let localInput = fs.readFileSync(
    join(UPGRADE_ENVS_DIR, currentEnvDir.replace("upgrade-envs/", ""), "local.toml"),
    "utf-8"
  );
  localInput = localInput.replace(
    /^# Local v\d+ -> v\d+ upgrade input\./m,
    `# Local v${current.minor} -> v${next.minor} upgrade input.`
  );
  localInput = setTomlBareValue(localInput, "old_protocol_version", packSemVer({ ...current, patch: 0 }));
  localInput = setTomlBareValue(localInput, "latest_protocol_version", packSemVer(next));
  write(join(nextEnvDirAbs, "local.toml"), localInput);

  // 3. protocol-ops' current upgrade-env dir.
  write(PROTOCOL_OPS_SCRIPTS_PATH, scripts.replace(ENV_DIR_MACRO_RE, `$1${nextEnvDir}$3`));

  // 4. Anvil fixture rotation.
  const anvilConfig = JSON.parse(fs.readFileSync(ANVIL_CONFIG_PATH, "utf-8")) as {
    stateVersion: string;
    upgradeSourceStateVersion: string;
  };
  const outgoingSource = anvilConfig.upgradeSourceStateVersion;
  const nextStateVersion = versionString(next);
  if (!fs.existsSync(join(CHAIN_STATES_DIR, anvilConfig.stateVersion))) {
    throw new Error(`chain-states/${anvilConfig.stateVersion} is missing: it becomes the upgrade source`);
  }
  const rotated = {
    ...anvilConfig,
    stateVersion: nextStateVersion,
    upgradeSourceStateVersion: anvilConfig.stateVersion,
  };
  write(ANVIL_CONFIG_PATH, `${JSON.stringify(rotated, null, 2)}\n`);
  if (outgoingSource !== anvilConfig.stateVersion) {
    const outgoingSourceDir = join(CHAIN_STATES_DIR, outgoingSource);
    changed.push(`delete ${relative(ROOT, outgoingSourceDir)}`);
    writes.push(() => fs.rmSync(outgoingSourceDir, { recursive: true, force: true }));
  }

  if (!dryRun) {
    writes.forEach((apply) => apply());
  }
  console.log(`${dryRun ? "[dry run] " : ""}Release ${versionString(current)} -> ${nextStateVersion} (${name}):`);
  changed.forEach((line) => console.log(`  ${line}`));
  console.log(`
Still to do:
  - Regenerate chain-states/${nextStateVersion} (the 'Regenerate Anvil Interop Chain States' workflow, or
    \`cd l1-contracts/test/anvil-interop && npx ts-node setup-and-dump-state.ts\`). Until then the interop
    tests have no states for ${nextStateVersion}; the upgrade test already runs ${anvilConfig.stateVersion} -> ${nextStateVersion}.
  - Add per-environment upgrade inputs (stage.toml, mainnet.toml, ...) to ${nextEnvDir}/ when preparing for them.
  - Only if the release needs release-specific preparation: add Core/CTM scripts extending the Default* ones
    under l1-contracts/deploy-scripts/upgrade/v${next.minor}/ and point protocol-ops' prepare defaults at them.
  - Run \`cd protocol-ops && cargo test\` and the upgrade tests (\`yarn ts-node run-upgrade-test.ts\` in
    l1-contracts/test/anvil-interop, \`forge test --ffi --match-path 'test/foundry/l1/integration/UpgradeTest*'\`).`);
}

main();
