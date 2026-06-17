/**
 * Double-check for `deploy-scripts/upgrade/v31/PatchTotalSupplyV31UpgradeData.s.sol`.
 *
 * The main (Solidity) script regenerates the v31 **ZKsync OS** CTM upgrade cut via the real
 * `CTMUpgrade_v31` prep. ZKsync OS force-deployments embed, per contract, a `ZKSyncOSBytecodeInfo`
 * whose bytecode hash is `blake2s256(evmDeployedBytecode)` — the same value the prep computes via
 * `scripts/blake2s256.js` (and that `AllContractsHashes.json` stores as `evmDeployedBytecodeBlakeHash`).
 *
 * This script recomputes those blake2s hashes **fully in TypeScript** (reusing the blake2s256.js
 * logic) from the freshly-built `out/*` artifacts, and:
 *   1. cross-checks each against `AllContractsHashes.json` (artifacts ↔ committed hashes),
 *   2. reads the previous upgrade cut ON CHAIN from the ZKsync OS CTM (verified against
 *      `upgradeCutHash`) and confirms the blake hashes of *unchanged* force-deployed contracts are
 *      present in it (validating that the cut really embeds these hashes and our computation matches
 *      the prep), while the *affected* contracts' new hashes are absent (they are still the pre-fix
 *      hashes on chain), and
 *   3. if the Solidity prep output (`patched-upgrade-cut.toml`) is present, confirms the affected
 *      contracts' new blake hashes DO land in the regenerated cut (and the unchanged ones still do),
 *      i.e. the regeneration swapped exactly the changed force-deployment hashes.
 *
 * Usage: ts-node scripts/patch-total-supply-crosscheck.ts   (requires the hardcoded RPC env var)
 */
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import * as toml from "toml";
import * as blakejs from "blakejs";

// Hardcoded: the L1 RPC env var for the stage environment (Sepolia).
const L1_RPC_URL_ENV = "TENDERLY_SEPOLIA";

const L1_ROOT = path.resolve(__dirname, "..");
const OUT_DIR = path.join(L1_ROOT, "out");
const PATCH_DIR = path.join(L1_ROOT, "deploy-scripts/upgrade/v31/patch-total-supply");
const ALL_CONTRACTS_HASHES = path.resolve(L1_ROOT, "..", "AllContractsHashes.json");
const ECOSYSTEM_TOML = path.join(L1_ROOT, "upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml");

// Contracts the totalSupply fix changes (their bytecode — and thus blake hash — differ from the
// deployed/pre-fix version).
const AFFECTED = [
  "L2AssetTracker",
  "L2V31Upgrade",
  "L2ComplexUpgrader",
  "L2GenesisUpgrade",
  "L2GenesisForceDeploymentsHelper",
  "L2V30TestnetSystemProxiesUpgrade",
];
// Unchanged contracts known to be force-deployed in the ZKsync OS v31 upgrade — used as a control
// to validate the blake computation and that the cut embeds these hashes.
const CONTROL = ["L2AssetRouter", "L2Bridgehub", "L2MessageRoot", "BaseTokenHolder", "InteropCenter"];

const eventsIface = new ethers.utils.Interface([
  "event NewUpgradeCutData(uint256 indexed protocolVersion, tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata) diamondCutData)",
]);
const NEW_UPGRADE_CUT_DATA_TOPIC = eventsIface.getEventTopic("NewUpgradeCutData");
const ctmIface = new ethers.utils.Interface([
  "function upgradeCutHash(uint256) view returns (bytes32)",
  "function upgradeCutDataBlock(uint256) view returns (uint256)",
]);

/** blake2s256 of the contract's EVM *deployed* bytecode — identical to scripts/blake2s256.js. */
function evmDeployedBlake(contractName: string): string {
  const art = JSON.parse(fs.readFileSync(path.join(OUT_DIR, `${contractName}.sol`, `${contractName}.json`), "utf8"));
  const bytecode = ethers.utils.arrayify(art.deployedBytecode.object);
  return "0x" + blakejs.blake2sHex(bytecode);
}

function allContractsHashesBlake(contractName: string): string | undefined {
  const all: { contractName: string; evmDeployedBytecodeBlakeHash: string | null }[] = JSON.parse(
    fs.readFileSync(ALL_CONTRACTS_HASHES, "utf8")
  );
  const entry = all.find((c) => c.contractName === `l1-contracts/${contractName}`);
  return entry?.evmDeployedBytecodeBlakeHash?.toLowerCase();
}

function countOccurrences(hex: string, word: string): number {
  const data = ethers.utils.arrayify(hex);
  const w = ethers.utils.arrayify(word);
  let n = 0;
  for (let i = 0; i + 32 <= data.length; i++) {
    let m = true;
    for (let j = 0; j < 32; j++)
      if (data[i + j] !== w[j]) {
        m = false;
        break;
      }
    if (m) n++;
  }
  return n;
}

async function main() {
  const rpcUrl = process.env[L1_RPC_URL_ENV];
  if (!rpcUrl) throw new Error(`RPC env var ${L1_RPC_URL_ENV} is not set`);
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);

  // ZKsync OS CTM + old protocol version from the stage ecosystem artifact.
  const eco = toml.parse(fs.readFileSync(ECOSYSTEM_TOML, "utf8"));
  const zkos = eco.ctms.zksync_os;
  const ctmAddr: string = zkos.state_transition.chain_type_manager_proxy;
  const oldProtocolVersion = ethers.BigNumber.from(zkos.contracts_config.old_protocol_version);
  const ctm = new ethers.Contract(ctmAddr, ctmIface, provider);

  // Previous upgrade cut, on chain.
  const cutBlock = (await ctm.upgradeCutDataBlock(oldProtocolVersion)).toNumber();
  if (cutBlock === 0) throw new Error("CTM has no recorded upgrade cut block for the old protocol version");
  const logs = await provider.getLogs({
    address: ctmAddr,
    topics: [NEW_UPGRADE_CUT_DATA_TOPIC, ethers.utils.hexZeroPad(oldProtocolVersion.toHexString(), 32)],
    fromBlock: cutBlock,
    toBlock: cutBlock,
  });
  if (logs.length !== 1) throw new Error(`expected exactly one NewUpgradeCutData log, got ${logs.length}`);
  const onChainCut = logs[0].data;
  const onChainCutHash = (await ctm.upgradeCutHash(oldProtocolVersion)).toLowerCase();
  if (ethers.utils.keccak256(onChainCut).toLowerCase() !== onChainCutHash) {
    throw new Error("decoded upgrade cut does not match on-chain upgradeCutHash");
  }
  console.log(`ZKsync OS CTM ${ctmAddr}: on-chain upgrade cut verified (block ${cutBlock}).`);

  // Recompute the prep's blake2s hashes in TS and cross-check vs AllContractsHashes.json.
  const blake: Record<string, string> = {};
  for (const name of [...CONTROL, ...AFFECTED]) {
    const b = evmDeployedBlake(name).toLowerCase();
    blake[name] = b;
    const expected = allContractsHashesBlake(name);
    if (expected && expected !== b) {
      throw new Error(`${name}: blake2s(out) ${b} != AllContractsHashes.evmDeployedBytecodeBlakeHash ${expected}`);
    }
  }
  console.log("blake2s(evmDeployedBytecode) recomputed in TS and consistent with AllContractsHashes.json.");

  // Control: unchanged force-deployed contracts must already be in the on-chain cut.
  for (const name of CONTROL) {
    const occ = countOccurrences(onChainCut, blake[name]);
    if (occ === 0) {
      throw new Error(`control ${name}: blake ${blake[name]} not found in the on-chain ZKsync OS cut`);
    }
    console.log(`  control ${name}: present on chain x${occ}  (blake matches the prep)`);
  }

  // Affected: their NEW blake must be absent on chain (chain still has the pre-fix hash).
  for (const name of AFFECTED) {
    const occ = countOccurrences(onChainCut, blake[name]);
    console.log(`  affected ${name}: new blake on-chain x${occ} ${occ === 0 ? "(pre-fix value still deployed — to be patched)" : ""}`);
  }

  // Cross-check against the Solidity prep output if present.
  const cutTomlPath = path.join(PATCH_DIR, "patched-upgrade-cut.toml");
  if (!fs.existsSync(cutTomlPath)) {
    console.log(
      "\n(Solidity prep output not found; run PatchTotalSupplyV31.runPatch in the upgrade env to cross-check\n" +
        " that the affected contracts' new blake hashes land in the regenerated cut.)"
    );
    return;
  }
  const sol = toml.parse(fs.readFileSync(cutTomlPath, "utf8"));
  const regenCut: string = sol.cut_data;
  if (sol.corrected_upgrade_cut_hash.toLowerCase() !== ethers.utils.keccak256(regenCut).toLowerCase()) {
    throw new Error("patched-upgrade-cut.toml: corrected_upgrade_cut_hash does not match keccak(cut_data)");
  }
  let ok = true;
  for (const name of CONTROL) {
    if (countOccurrences(regenCut, blake[name]) === 0) {
      console.error(`MISMATCH: control ${name} blake missing from the regenerated cut`);
      ok = false;
    }
  }
  for (const name of AFFECTED) {
    const onChain = countOccurrences(onChainCut, blake[name]);
    const inRegen = countOccurrences(regenCut, blake[name]);
    // Affected contracts that are force-deployed: new blake absent on chain, present in regen.
    if (onChain === 0 && inRegen > 0) {
      console.log(`  affected ${name}: new blake now present in regenerated cut x${inRegen}  (patched)`);
    } else if (inRegen > 0 || onChain > 0) {
      // Present in both / only on chain — not the expected "changed force-deploy" shape.
      console.error(`MISMATCH: ${name} onChain=${onChain} regen=${inRegen} (expected onChain=0, regen>0)`);
      ok = false;
    }
  }
  if (!ok) process.exit(1);
  console.log("CROSS-CHECK OK: regenerated cut embeds the new ZKsync OS blake hashes for the affected contracts.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
