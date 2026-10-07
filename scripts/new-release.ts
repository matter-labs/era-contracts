import { execFileSync } from "child_process";
import { randomBytes } from "crypto";
import * as fs from "fs";
import { join, relative } from "path";

// Starts a new protocol release on the current branch: moves every place that names "the current release"
// to the next minor version, so the default upgrade (protocol-ops' `upgrade-prepare-all` defaults) and the
// upgrade tests target it. Usage:
//
//   yarn new-release <name> [--previous-release-ref <git-ref>] [--dry-run]
//
// e.g. on the next release's branch, after merging the outgoing release's branch into it:
//   yarn new-release my-feature --previous-release-ref origin/draft/v0.34.0
//
// `--previous-release-ref` names the outgoing release's branch. Its `chain-states/<stateVersion>` become the
// upgrade test's frozen source, copied byte for byte: on a branch that already carries the next release's
// changes, the local folder of that name was regenerated from newer contracts and is not the release's
// fixture. Without the flag the local folder is used, which is right only on the outgoing release's own branch.
//
// What it changes:
//   1. `configs/genesis/zksync-os/latest.json` `protocol_semantic_version`: minor + 1, patch 0. The default
//      upgrade scripts read their target version from it, and the upgrade tests assert it.
//   2. `l1-contracts/upgrade-envs/v0.<minor>.0-<name>/`: the local upgrade input and every per-environment
//      input (`stage.toml`, `mainnet.toml`, ...), copied from the current release's. They carry no version
//      fields: the scripts read the old version from the CTM and the target from genesis. Environment values (owner, era_chain_id, addresses) carry over; every CREATE2 and legacy-Gov salt
//      is regenerated, so the new release's deployments do not resolve to the previous release's addresses.
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

function versionString(version: SemVer): string {
  return `v${version.major}.${version.minor}.${version.patch}`;
}

const RELEASE_NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const VERSION_BLOCK_RE =
  /("protocol_semantic_version":\s*\{\s*"major":\s*)(\d+)(,\s*"minor":\s*)(\d+)(,\s*"patch":\s*)(\d+)/;
const ENV_DIR_MACRO_RE = /(macro_rules! current_upgrade_env_dir \{\s*\(\) => \{\s*")(upgrade-envs\/[^"]+)(")/;

type SemVer = { major: number; minor: number; patch: number };

const SALT_KEYS = ["create2_factory_salt", "legacy_gov_salt"];

function freshSalt(): string {
  return `"0x${randomBytes(32).toString("hex")}"`;
}

/** Header of a per-environment upgrade input; the same text every release writes. */
function envInputHeader(env: string, release: SemVer, sourceDir: string): string {
  return `# Upgrade input for the ${env} environment on the v${release.minor} release.
#
# Created from the ${sourceDir} entry of the same name: the environment values (owner,
# era_chain_id, bridgehub and the other addresses) are carried over, while the CREATE2 and legacy-Gov
# salts are fresh, so this release's deployments do not resolve to v${release.minor - 1}'s addresses. The target protocol
# version and chain-creation params come from \`configs/genesis/zksync-os/latest.json\`.
#
# protocol-ops' \`--env ${env}\` reads this file (its owner, era_chain_id and salts) for the current release;
# a missing file fails closed rather than falling back to local's values.
`;
}

/** A per-environment input for the next release: new header and versions, fresh salts. */
function rotateEnvInput(contents: string, env: string, next: SemVer, sourceDir: string): string {
  const lines = contents.split("\n");
  let start = 0;
  while (start < lines.length && (lines[start].startsWith("#") || lines[start].trim() === "")) {
    start++;
  }
  let body = lines.slice(start).join("\n");
  for (const key of SALT_KEYS) {
    body = body.replace(new RegExp(`^(${key}\\s*=\\s*)"0x[0-9a-fA-F]{64}"`, "m"), (_m, prefix) => prefix + freshSalt());
  }
  body = body.replace(/^\[create2_factory_salts\]\n(?:(?!\[).*\n?)*/m, (section) =>
    section.replace(/(=\s*)"0x[0-9a-fA-F]{64}"/g, (_m, prefix) => prefix + freshSalt())
  );
  return `${envInputHeader(env, next, sourceDir)}\n${body}`;
}

function main(): void {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const refFlag = args.indexOf("--previous-release-ref");
  const previousReleaseRef = refFlag >= 0 ? args[refFlag + 1] : undefined;
  const positional = args.filter((arg, i) => !arg.startsWith("--") && !(refFlag >= 0 && i === refFlag + 1));
  if (positional.length !== 1 || !RELEASE_NAME_RE.test(positional[0]) || (refFlag >= 0 && !previousReleaseRef)) {
    throw new Error("usage: yarn new-release <kebab-case-name> [--previous-release-ref <git-ref>] [--dry-run]");
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
  // The branch must already be on the release it moves away from: genesis and protocol-ops' current release
  // agree. A branch that has not merged the outgoing release yet would otherwise be bumped from a stale version.
  const envDirVersion = currentEnvDir.match(/^upgrade-envs\/v(\d+)\.(\d+)\.\d+-/);
  if (!envDirVersion || Number(envDirVersion[1]) !== current.major || Number(envDirVersion[2]) !== current.minor) {
    throw new Error(
      `genesis is at ${versionString(current)} but protocol-ops' current release is ${currentEnvDir}; ` +
        "merge the outgoing release's branch first"
    );
  }
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
    /^# Local v\d+ -> v\d+ upgrade input\..*$/m,
    `# Local v${current.minor} -> v${next.minor} upgrade input.`
  );
  write(join(nextEnvDirAbs, "local.toml"), localInput);
  const currentEnvDirAbs = join(UPGRADE_ENVS_DIR, currentEnvDir.replace("upgrade-envs/", ""));
  for (const file of fs.readdirSync(currentEnvDirAbs).filter((f) => f.endsWith(".toml") && f !== "local.toml")) {
    const env = file.replace(/\.toml$/, "");
    const contents = fs.readFileSync(join(currentEnvDirAbs, file), "utf-8");
    write(join(nextEnvDirAbs, file), rotateEnvInput(contents, env, next, currentEnvDir.replace("upgrade-envs/", "")));
  }

  // 3. protocol-ops' current upgrade-env dir.
  write(PROTOCOL_OPS_SCRIPTS_PATH, scripts.replace(ENV_DIR_MACRO_RE, `$1${nextEnvDir}$3`));

  // 4. Anvil fixture rotation.
  const anvilConfig = JSON.parse(fs.readFileSync(ANVIL_CONFIG_PATH, "utf-8")) as {
    stateVersion: string;
    upgradeSourceStateVersion: string;
  };
  const outgoingSource = anvilConfig.upgradeSourceStateVersion;
  const nextStateVersion = versionString(next);
  const frozenSourceDir = join(CHAIN_STATES_DIR, anvilConfig.stateVersion);
  if (previousReleaseRef) {
    const repoPath = (absolute: string) => relative(ROOT, absolute).split("\\").join("/");
    const git = (gitArgs: string[]) => execFileSync("git", gitArgs, { cwd: ROOT, maxBuffer: 1 << 30 });
    const refConfig = JSON.parse(git(["show", `${previousReleaseRef}:${repoPath(ANVIL_CONFIG_PATH)}`]).toString()) as {
      stateVersion: string;
    };
    if (refConfig.stateVersion !== anvilConfig.stateVersion) {
      throw new Error(
        `${previousReleaseRef} generates ${refConfig.stateVersion}, not ${anvilConfig.stateVersion}: not the outgoing release`
      );
    }
    const files = git(["ls-tree", "--name-only", `${previousReleaseRef}:${repoPath(frozenSourceDir)}`])
      .toString()
      .split("\n")
      .filter(Boolean);
    if (files.length === 0) {
      throw new Error(`${previousReleaseRef} has no chain-states/${anvilConfig.stateVersion}`);
    }
    changed.push(`freeze  ${repoPath(frozenSourceDir)} from ${previousReleaseRef}`);
    writes.push(() => {
      fs.rmSync(frozenSourceDir, { recursive: true, force: true });
      fs.mkdirSync(frozenSourceDir, { recursive: true });
      for (const file of files) {
        fs.writeFileSync(
          join(frozenSourceDir, file),
          git(["show", `${previousReleaseRef}:${repoPath(join(frozenSourceDir, file))}`])
        );
      }
    });
  } else if (!fs.existsSync(frozenSourceDir)) {
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
  - Review the per-environment inputs copied into ${nextEnvDir}/ (owner, era_chain_id and addresses carry over).
  - Point protocol-ops' --core-script-path / --ctm-script-path defaults (protocol-ops/src/commands/ecosystem/upgrade.rs)
    at this release's scripts: back to DefaultCoreUpgrade / DefaultCTMUpgrade, or, if the release needs
    release-specific preparation, at new scripts extending them under l1-contracts/deploy-scripts/upgrade/v${next.minor}/.
    UpgradeTest_Local's CTM subclass must extend the same CTM script. protocol-ops' cargo test fails until both
    are done (release_specific_defaults_belong_to_the_current_release, prepare_defaults_match_the_foundry_full_flow_test).
  - Run \`cd protocol-ops && cargo test\` and the upgrade tests (\`yarn ts-node run-upgrade-test.ts\` in
    l1-contracts/test/anvil-interop, \`forge test --ffi --match-path 'test/foundry/l1/integration/UpgradeTest*'\`).`);
}

main();
