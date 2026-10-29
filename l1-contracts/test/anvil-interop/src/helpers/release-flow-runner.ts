/**
 * The release flow (.github/workflows/README.md#release-flow): the ecosystem-upgrade workflows'
 * protocol-ops commands, the governance calls and a partner's chain commands, on the previous release's
 * frozen L1 (`upgradeSourceStateVersion`) through the `anvil-interop` env. With PROTOCOL_OPS_TAG set
 * (build-docker.yaml; Linux, for the host network), every command runs in that image, the chain commands by `docker run` as
 * docs/protocol-ops-for-partners.md runs them; else from this checkout.
 *
 * Unlike `runPipelineUpgradeScenario`, it runs the env's committed configs, the only ones an image holds.
 * Not `chain upgrade`: the fixture's chains still have the previous upgrade's L2 transaction pending.
 */

import { spawnSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as zlib from "zlib";
import { ethers } from "ethers";
import { parse as parseToml } from "toml";
import { AnvilManager } from "../daemons/anvil-manager";
import { DeploymentRunner } from "../deployment-runner";
import { readStateVersion } from "../core/anvil-config";
import { ANVIL_DEFAULT_PRIVATE_KEY } from "../core/const";
import { getAbi } from "../core/contracts";
import type { DeploymentState } from "../core/types";
import { createProvider, impersonateAndRun } from "../core/utils";
import { deployChainAdmins, executeSafeBundles, runProtocolOps, transferL1Ownership } from "./pipeline-upgrade-runner";
import { selectUpgradeChains } from "./upgrade-test-utils";

const ENV = "anvil-interop";
const UPGRADE_TIMESTAMP = 1_900_000_000;
const VALIDATOR = "0x1111111111111111111111111111111111111111";

const anvilInteropDir = path.resolve(__dirname, "../..");
const contractsRootDir = path.resolve(anvilInteropDir, "../../..");
const upgradeEnvsDir = path.join(contractsRootDir, "l1-contracts", "upgrade-envs");

/** A command line's arguments; its values contain no whitespace. */
const words = (command: string) => command.trim().split(/\s+/);

export async function runReleaseFlow(): Promise<void> {
  const tag = process.env.PROTOCOL_OPS_TAG || undefined;
  const image = tag && `ghcr.io/matter-labs/protocol-ops${tag.startsWith("sha256:") ? "@" : ":"}${tag}`;
  const fixture = path.join(anvilInteropDir, "chain-states", readStateVersion("upgradeSourceStateVersion"));
  const { l1Addresses, ctmAddresses, chainAddresses, zkToken } = JSON.parse(
    fs.readFileSync(path.join(fixture, "addresses.json"), "utf8")
  ) as Required<DeploymentState>;
  const config = new DeploymentRunner().getConfig();
  const l1Config = config.chains.find((chain) => chain.role === "l1")!;
  // The partner's chain: one that settles on L1, so its operations are L1 bundles.
  const [chain] = selectUpgradeChains(chainAddresses, config.chains, ["directSettled"]);
  const upgrade = fs
    .readdirSync(upgradeEnvsDir)
    .filter((dir) => dir.startsWith("v") && fs.existsSync(path.join(upgradeEnvsDir, dir, `${ENV}.toml`)))
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))
    .pop()!;
  // Relative to the checkout: in the image, the upgrade's output directory is mounted at the same place.
  const out = `l1-contracts/upgrade-envs/${upgrade}/output/${ENV}`;
  // The fixture values no later command holds the env to: protocol-ops gives a CTM the release input has no
  // salt for a random one, and compares the ZK asset id only with the env itself.
  const preset = parseToml(fs.readFileSync(path.join(upgradeEnvsDir, "permanent-values", `${ENV}.toml`), "utf8"));
  const input = parseToml(fs.readFileSync(path.join(upgradeEnvsDir, upgrade, `${ENV}.toml`), "utf8"));
  const saltedCtms = Object.keys(input.create2_factory_salts ?? {}).map((ctm) => ctm.toLowerCase());
  if (
    preset.zk_token_asset_id?.toLowerCase() !== zkToken.assetId.toLowerCase() ||
    !saltedCtms.includes(ctmAddresses.chainTypeManager.toLowerCase())
  ) {
    throw new Error(`copy ${fixture}/addresses.json's zkToken.assetId and chainTypeManager into the ${ENV} configs`);
  }

  const anvilManager = new AnvilManager();
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "release-flow-"));
  // The deploy workflow's downloaded bundle, mounted read-only, and its results.
  const bundle = path.join(work, "bundle");
  const result = path.join(work, "result");
  fs.mkdirSync(bundle);
  fs.mkdirSync(result);
  const po = (command: string) =>
    runProtocolOps([...(tag ? ["--tag", tag] : []), ...words(command)], {
      EXTRA_MOUNTS: `${bundle}:${bundle}:ro ${result}:${result}`,
    });
  try {
    const l1StatePath = path.join(work, "l1-state.json");
    fs.writeFileSync(l1StatePath, zlib.gunzipSync(fs.readFileSync(path.join(fixture, `${l1Config.chainId}.json.gz`))));
    await anvilManager.startChain({ ...l1Config, loadStatePath: l1StatePath, blockTime: 0 });
    const l1 = anvilManager.getL1Chain()!.rpcUrl;
    const provider = createProvider(l1);
    const deployer = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
    // Production-shaped ownership, and the ChainAdmin a chain gets at registration, as the upgrade test's.
    await transferL1Ownership(provider, deployer, l1Addresses, ctmAddresses);
    await deployChainAdmins(provider, deployer, [chain]);

    console.log(`\n── generate: ${upgrade} ──`);
    po(`ecosystem rehearse-upgrade --upgrade ${upgrade} --env ${ENV} --fork-url ${l1}
        --deployer-address ${deployer.address}`);
    po(`ecosystem governance-toml-to-simulator --env ${ENV} --include-manifest ${out}/prepare/manifest.json
        --camp-a-signers ${deployer.address} --emit-sim-inputs ${out}/sim-inputs`);
    po(`ecosystem governance-toml-to-simulator --env ${ENV} --out ${out}/transaction-simulator.json`);

    console.log("\n── handoff ──");
    fs.cpSync(path.join(contractsRootDir, out, "deploy-bundle"), bundle, { recursive: true });
    po(`ecosystem replay-bundle --bundle ${bundle} --fork-url ${l1}`);
    if (tag) {
      const metadata = JSON.parse(fs.readFileSync(path.join(bundle, "bundle-metadata.json"), "utf8"));
      const head = spawnSync("git", ["rev-parse", "HEAD"], { cwd: contractsRootDir, encoding: "utf8" }).stdout.trim();
      if (
        !metadata.protocol_ops_image?.reference?.endsWith(tag) ||
        metadata.contracts_commit !== head ||
        "contracts_worktree_dirty" in metadata ||
        metadata.zk_governance_commit?.length !== 40
      ) {
        throw new Error("the bundle's metadata does not record the image and its commits");
      }
    }

    console.log("\n── deploy ──");
    po(`ecosystem verify-bundle ${bundle}`);
    po(`ecosystem upgrade-broadcast --manifest ${bundle}/prepare/manifest.json --l1-rpc-url ${l1} --skip-unkeyed
        --key ${deployer.address}=${deployer.privateKey} --max-gas-price-gwei 500 --out ${result}/deploy-executed.json`);
    po(`ecosystem replay-bundle --bundle ${bundle} --rpc ${l1} --verify-only`);

    console.log("\n── govern ──");
    const calls = JSON.parse(
      fs.readFileSync(path.join(contractsRootDir, out, "transaction-simulator.json"), "utf8")
    ) as Array<{ from: string; to: string; data: string; value: string; tag: string }>;
    const governanceCalls = calls.filter((call) => call.tag === "governance");
    if (governanceCalls.length === 0) {
      throw new Error("the simulator export has no governance call");
    }
    for (const call of governanceCalls) {
      // The export's values are in ETH.
      const value = ethers.utils.parseEther(call.value);
      await impersonateAndRun(provider, call.from, async (signer) =>
        (await signer.sendTransaction({ to: call.to, data: call.data, value })).wait()
      );
    }

    console.log(`\n── chain ${chain.chainId} ──`);
    // A partner's chain command, then its bundles sent.
    const chainOp = async (command: string) => {
      const dir = fs.mkdtempSync(path.join(work, "chain-"));
      const chainCommand = `chain ${command} --env ${ENV} --chain-id ${chain.chainId} --l1-rpc-url ${l1}`;
      if (!image) {
        runProtocolOps(words(`${chainCommand} --out ${dir}`));
      } else {
        const docker = words(`run --rm --platform linux/amd64 --network=host -v ${dir}:/out ${image}
          protocol_ops ${chainCommand} --out /out`);
        if (spawnSync("docker", docker, { stdio: "inherit" }).status !== 0) {
          throw new Error(`docker ${docker.join(" ")} failed`);
        }
      }
      await executeSafeBundles(dir, l1, "chain-operation");
    };
    const ctm = new ethers.Contract(ctmAddresses.chainTypeManager, getAbi("IChainTypeManager"), provider);

    // INC-38's call: the timestamp must land on the version the chain upgrades from.
    await chainOp(`set-upgrade-timestamp --upgrade-timestamp ${UPGRADE_TIMESTAMP}`);
    const version: ethers.BigNumber = await ctm.getProtocolVersion(chain.chainId);
    const serverNotifier = new ethers.Contract(await ctm.serverNotifierAddress(), getAbi("ServerNotifier"), provider);
    const scheduled: ethers.BigNumber = await serverNotifier.protocolVersionToUpgradeTimestamp(chain.chainId, version);
    if (!scheduled.eq(UPGRADE_TIMESTAMP)) {
      throw new Error(`chain ${chain.chainId}'s upgrade timestamp for version ${version} is ${scheduled}`);
    }

    await chainOp(`add-validator --validator-address ${VALIDATOR}`);
    const timelock = new ethers.Contract(await ctm.validatorTimelockPostV29(), getAbi("IValidatorTimelock"), provider);
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
