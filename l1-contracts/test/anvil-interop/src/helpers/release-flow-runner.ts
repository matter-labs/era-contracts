/**
 * The release flow: the ecosystem-upgrade workflows' protocol-ops commands, end to end, on the
 * previous release's frozen fixture (`upgradeSourceStateVersion`) through the env preset that names it
 * (`anvil-interop`):
 *
 *   1. generate: `rehearse-upgrade` and the simulator export (generate-ecosystem-upgrade-calldata.yaml).
 *   2. handoff: `replay-bundle --fork-url` (its verify-bundle-handoff job).
 *   3. deploy: `verify-bundle`, `upgrade-broadcast` with the deployer key (deploy-ecosystem-upgrade.yaml),
 *      then `replay-bundle --verify-only` on the result.
 *   4. govern: the simulator export's governance calls, as the vote executes them.
 *   5. chain: a partner's chain operations, `set-upgrade-timestamp` and `add-validator`, run the way
 *      docs/protocol-ops-for-partners.md runs them, with their bundles sent and their effect read back
 *      on L1. Not `chain upgrade`: the fixture's chains still have the previous upgrade's L2 transaction
 *      pending, which an L1-only run can't finalize (`runPipelineUpgradeScenario` relays it).
 *
 * The commands only: every phase runs one unpushed image (or this checkout), so the bundle names no
 * registry digest, and the workflows' own digest and commit checks don't run here. The bundle is still
 * copied out and mounted read-only, as their downloaded artifact is.
 *
 * With PROTOCOL_OPS_TAG set (build-docker.yaml; Linux, for the host network), every command runs in
 * that image: through `protocol-ops.sh --tag`, and a partner's by `docker run`. Else from this checkout.
 * Unlike `runPipelineUpgradeScenario`, it runs the env's committed configs, the only ones an image holds.
 */

import { spawnSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as zlib from "zlib";
import { parse as parseToml } from "toml";
import { ethers } from "ethers";
import { AnvilManager } from "../daemons/anvil-manager";
import { DeploymentRunner } from "../deployment-runner";
import { readStateVersion } from "../core/anvil-config";
import { ANVIL_DEFAULT_PRIVATE_KEY } from "../core/const";
import { getAbi } from "../core/contracts";
import { createProvider, impersonateAndRun } from "../core/utils";
import { deployChainAdmins, executeSafeBundles, runProtocolOps, transferL1Ownership } from "./pipeline-upgrade-runner";
import { selectUpgradeChains } from "./upgrade-test-utils";

const ENV = "anvil-interop";
// What the chain phase sets on its chain.
const UPGRADE_TIMESTAMP = 1_900_000_000;
const VALIDATOR = "0x1111111111111111111111111111111111111111";

const anvilInteropDir = path.resolve(__dirname, "../..");
const l1ContractsDir = path.resolve(anvilInteropDir, "../..");
const contractsRootDir = path.resolve(l1ContractsDir, "..");
const upgradeEnvsDir = path.join(l1ContractsDir, "upgrade-envs");

type FixtureAddresses = {
  l1Addresses: {
    bridgehub: string;
    governance: string;
    l1SharedBridge: string;
    l1NativeTokenVault: string;
    l1NullifierProxy?: string;
  };
  ctmAddresses: { chainTypeManager: string };
  chainAddresses: Array<{ chainId: number; diamondProxy: string }>;
  zkToken: { assetId: string };
};

/** One call of the simulator export (`governance-toml-to-simulator --out`); `value` is in ETH. */
type SimulatorCall = { from: string; to: string; data: string; value: string; tag: string };

export async function runReleaseFlow(): Promise<void> {
  const tag = process.env.PROTOCOL_OPS_TAG || undefined;
  const fixture = path.join(anvilInteropDir, "chain-states", readStateVersion("upgradeSourceStateVersion"));
  const addresses = JSON.parse(fs.readFileSync(path.join(fixture, "addresses.json"), "utf8")) as FixtureAddresses;
  const { l1Addresses, ctmAddresses } = addresses;
  const input = newestUpgradeInput();
  requireFixtureNamed(addresses, input);

  const config = new DeploymentRunner().getConfig();
  const l1Config = config.chains.find((chain) => chain.role === "l1");
  if (!l1Config) {
    throw new Error("anvil-config.json has no L1");
  }
  // The partner's chain: one that settles on L1, so its operations are L1 bundles.
  const [chain] = selectUpgradeChains(addresses.chainAddresses, config.chains, ["directSettled"]);
  if (!chain) {
    throw new Error(`${fixture} has no chain settling on L1`);
  }

  const anvilManager = new AnvilManager();
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "release-flow-"));
  try {
    console.log(`\n── L1: ${fixture} ──`);
    const l1StatePath = path.join(work, "l1-state.json");
    fs.writeFileSync(l1StatePath, zlib.gunzipSync(fs.readFileSync(path.join(fixture, `${l1Config.chainId}.json.gz`))));
    await anvilManager.startChain({ ...l1Config, loadStatePath: l1StatePath, blockTime: 0 });
    const l1RpcUrl = anvilManager.getL1Chain()!.rpcUrl;
    const l1Provider = createProvider(l1RpcUrl);
    const deployer = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);

    // Production-shaped ownership, as the upgrade test's.
    await transferL1Ownership(l1Provider, deployer, l1Addresses, ctmAddresses);

    const protocolOps = (args: string[], extraEnv?: Record<string, string>) =>
      runProtocolOps(tag ? ["--tag", tag, ...args] : args, extraEnv);

    console.log("\n── generate ──");
    protocolOps([
      "ecosystem",
      "rehearse-upgrade",
      "--env",
      ENV,
      "--fork-url",
      l1RpcUrl,
      "--deployer-address",
      deployer.address,
    ]);
    // Relative to the checkout: in the image, its output directory is mounted at the same place.
    const out = path.relative(contractsRootDir, path.join(path.dirname(input), "output", ENV));
    protocolOps([
      "ecosystem",
      "governance-toml-to-simulator",
      "--env",
      ENV,
      "--include-manifest",
      path.join(out, "prepare", "manifest.json"),
      "--camp-a-signers",
      deployer.address,
      "--emit-sim-inputs",
      path.join(out, "sim-inputs"),
    ]);
    const simulatorExport = path.join(out, "transaction-simulator.json");
    protocolOps(["ecosystem", "governance-toml-to-simulator", "--env", ENV, "--out", simulatorExport]);
    const simInputs = JSON.parse(readFromCheckout(path.join(out, "sim-inputs", "manifest.json"))) as {
      bundles?: unknown;
    };
    const governanceCalls = (JSON.parse(readFromCheckout(simulatorExport)) as SimulatorCall[]).filter(
      (call) => call.tag === "governance"
    );
    if (!simInputs.bundles || !governanceCalls.some((call) => sameAddress(call.from, l1Addresses.governance))) {
      throw new Error("the simulator export has no sim-inputs bundles or no governance call");
    }

    console.log("\n── handoff ──");
    const bundle = path.join(work, "bundle");
    const result = path.join(work, "result");
    fs.cpSync(path.join(contractsRootDir, out, "deploy-bundle"), bundle, { recursive: true });
    fs.mkdirSync(result);
    const mounts = { EXTRA_MOUNTS: `${bundle}:${bundle}:ro ${result}:${result}` };
    protocolOps(["ecosystem", "replay-bundle", "--bundle", bundle, "--fork-url", l1RpcUrl], mounts);
    if (tag) {
      assertBundleMetadata(path.join(bundle, "bundle-metadata.json"), tag);
    }

    console.log("\n── deploy ──");
    protocolOps(["ecosystem", "verify-bundle", bundle], mounts);
    protocolOps(
      [
        "ecosystem",
        "upgrade-broadcast",
        "--manifest",
        path.join(bundle, "prepare", "manifest.json"),
        "--l1-rpc-url",
        l1RpcUrl,
        "--key",
        `${deployer.address}=${deployer.privateKey}`,
        "--skip-unkeyed",
        "--max-gas-price-gwei",
        "500",
        "--out",
        path.join(result, "deploy-executed.json"),
      ],
      mounts
    );
    if (!(fs.statSync(path.join(result, "transactions.txt"), { throwIfNoEntry: false })?.size ?? 0)) {
      throw new Error(`upgrade-broadcast recorded no transactions in ${result}/transactions.txt`);
    }
    protocolOps(["ecosystem", "replay-bundle", "--bundle", bundle, "--rpc", l1RpcUrl, "--verify-only"], mounts);

    console.log("\n── govern ──");
    for (const call of governanceCalls) {
      await impersonateAndRun(l1Provider, call.from, async (signer) => {
        const tx = await signer.sendTransaction({
          to: call.to,
          data: call.data,
          value: ethers.utils.parseEther(call.value),
        });
        return tx.wait();
      });
    }

    console.log(`\n── chain ${chain.chainId} ──`);
    // The fixture's chains have an EOA admin; the commands need a ChainAdmin, as `RegisterZKChain`
    // deploys one (Ownable, owned by that EOA).
    await deployChainAdmins(l1Provider, deployer, [chain]);
    const chainOp = (name: string, args: string[]): string => {
      const dir = path.join(work, name);
      fs.mkdirSync(dir);
      runChainOp(tag, dir, [name, ...args, "--env", ENV, "--chain-id", `${chain.chainId}`, "--l1-rpc-url", l1RpcUrl]);
      return dir;
    };
    const ctm = new ethers.Contract(ctmAddresses.chainTypeManager, getAbi("IChainTypeManager"), l1Provider);

    // INC-38's call: the timestamp must land on the version the chain upgrades from.
    await executeSafeBundles(
      chainOp("set-upgrade-timestamp", ["--upgrade-timestamp", `${UPGRADE_TIMESTAMP}`]),
      l1RpcUrl,
      "chain-operation"
    );
    const version: ethers.BigNumber = await ctm.getProtocolVersion(chain.chainId);
    const serverNotifier = new ethers.Contract(await ctm.serverNotifierAddress(), getAbi("ServerNotifier"), l1Provider);
    const scheduled: ethers.BigNumber = await serverNotifier.protocolVersionToUpgradeTimestamp(chain.chainId, version);
    if (!scheduled.eq(UPGRADE_TIMESTAMP)) {
      throw new Error(
        `chain ${chain.chainId}'s upgrade timestamp for its version ${version} is ${scheduled}, not ${UPGRADE_TIMESTAMP}`
      );
    }

    await executeSafeBundles(chainOp("add-validator", ["--validator-address", VALIDATOR]), l1RpcUrl, "chain-operation");
    const timelock = new ethers.Contract(
      await ctm.validatorTimelockPostV29(),
      getAbi("IValidatorTimelock"),
      l1Provider
    );
    for (const role of ["COMMITTER_ROLE", "PROVER_ROLE", "EXECUTOR_ROLE"]) {
      if (!(await timelock.hasRoleForChainId(chain.chainId, await timelock[role](), VALIDATOR))) {
        throw new Error(`${VALIDATOR} has no ${role} for chain ${chain.chainId}`);
      }
    }
    console.log("\n✅ Release flow passed");
  } finally {
    await anvilManager.stopAll();
    fs.rmSync(work, { recursive: true, force: true });
  }
}

/** The newest upgrade's input for ENV, the one `--env` resolves to by default. */
function newestUpgradeInput(): string {
  const version = (dir: string) => (/^v(\d+)\.(\d+)\.(\d+)/.exec(dir) ?? []).slice(1).map(Number);
  const [newest] = fs
    .readdirSync(upgradeEnvsDir)
    .filter((dir) => version(dir).length === 3 && fs.existsSync(path.join(upgradeEnvsDir, dir, `${ENV}.toml`)))
    .sort((a, b) => {
      const [va, vb] = [version(a), version(b)];
      return vb[0] - va[0] || vb[1] - va[1] || vb[2] - va[2];
    });
  if (!newest) {
    throw new Error(`no upgrade in ${upgradeEnvsDir} has ${ENV}.toml`);
  }
  return path.join(upgradeEnvsDir, newest, `${ENV}.toml`);
}

/** The env must name the fixture's values: `yarn new-release` moves the fixture, and its addresses are copied in. */
function requireFixtureNamed(addresses: FixtureAddresses, input: string): void {
  const presetPath = path.join(upgradeEnvsDir, "permanent-values", `${ENV}.toml`);
  const preset = parseToml(fs.readFileSync(presetPath, "utf8"));
  const upgrade = parseToml(fs.readFileSync(input, "utf8"));
  const ctm = addresses.ctmAddresses.chainTypeManager;
  const missing = [
    !sameAddress(preset.core_contracts?.bridgehub_proxy_addr, addresses.l1Addresses.bridgehub) &&
      `${presetPath}: core_contracts.bridgehub_proxy_addr`,
    !(preset.ctm_contracts?.ctms ?? []).some((entry: { proxy?: string }) => sameAddress(entry.proxy, ctm)) &&
      `${presetPath}: ctm_contracts.ctms`,
    preset.zk_token_asset_id?.toLowerCase() !== addresses.zkToken.assetId.toLowerCase() &&
      `${presetPath}: zk_token_asset_id`,
    !sameAddress(upgrade.owner_address, addresses.l1Addresses.governance) && `${input}: owner_address`,
    !Object.keys(upgrade.create2_factory_salts ?? {}).some((proxy) => sameAddress(proxy, ctm)) &&
      `${input}: create2_factory_salts`,
  ].filter(Boolean);
  if (missing.length > 0) {
    throw new Error(`the fixture's addresses are not in ${missing.join(", ")}: copy them from its addresses.json`);
  }
}

/** The bundle records the image it was generated in and that image's commits. */
function assertBundleMetadata(metadataPath: string, tag: string): void {
  const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8")) as {
    protocol_ops_image?: { reference?: string };
    contracts_commit?: string;
    contracts_worktree_dirty?: boolean;
    zk_governance_commit?: string;
  };
  const head = spawnSync("git", ["rev-parse", "HEAD"], { cwd: contractsRootDir, encoding: "utf8" }).stdout.trim();
  if (
    !metadata.protocol_ops_image?.reference?.endsWith(tag) ||
    metadata.contracts_commit !== head ||
    "contracts_worktree_dirty" in metadata ||
    metadata.zk_governance_commit?.length !== 40
  ) {
    throw new Error(`${metadataPath} does not record the image and its commits`);
  }
}

/**
 * `protocol_ops chain <args> --out <dir>` as a partner runs it: `docker run` on the image, with its own
 * configs and an empty `out/` mounted (docs/protocol-ops-for-partners.md). From this checkout without an image.
 */
function runChainOp(tag: string | undefined, dir: string, args: string[]): void {
  if (!tag) {
    runProtocolOps(["chain", ...args, "--out", dir]);
    return;
  }
  const image = `ghcr.io/matter-labs/protocol-ops${tag.startsWith("sha256:") ? "@" : ":"}${tag}`;
  const run = spawnSync(
    "docker",
    ["run", "--rm", "--platform", "linux/amd64", "--network=host", "-v", `${dir}:/out`, image].concat([
      "protocol_ops",
      "chain",
      ...args,
      "--out",
      "/out",
    ]),
    { stdio: "inherit" }
  );
  if (run.status !== 0) {
    throw new Error(`docker run ${image} protocol_ops chain ${args.join(" ")} failed`);
  }
}

/** A file under the checkout, by its path relative to it. */
function readFromCheckout(relativePath: string): string {
  return fs.readFileSync(path.join(contractsRootDir, relativePath), "utf8");
}

function sameAddress(a: string | undefined, b: string): boolean {
  return a?.toLowerCase() === b.toLowerCase();
}
