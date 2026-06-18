// SPDX-License-Identifier: MIT
//
// Verifier (hashes-only, on-chain-sourced) for the ZKsync OS CTM patch proposal
// produced by `PatchZkosCtmAssetTracker.s.sol`, motivated by
// https://github.com/matter-labs/era-contracts/pull/2224.
//
// The forge script writes a dedicated patch proposal
// (`zkos-asset-tracker-patch.toml`). This script CHECKS that proposal. It never
// touches bytecode and never trusts the prepared ecosystem outputs for data:
//
//   1. it reads ONLY the ZKsync OS ChainTypeManager (CTM) address from the
//      ecosystem output, then queries the *original* on-chain data from the CTM's
//      own events (`NewChainCreationParams`, `NewUpgradeCutData`, `NewProtocolVersion`);
//   2. it asserts the patched chain-creation params / upgrade data differ from
//      the on-chain originals ONLY in the bytecode-descriptor substrings that
//      `AllContractsHashes.json` says changed (a high-level byte substitution:
//      take every substring that should have changed and replace it, then compare);
//   3. it asserts the ChainTypeManager calls in the proposal were constructed
//      correctly (`setChainCreationParams` + `setUpgradeDiamondCut`, right
//      target / args / old protocol version, bundled as `Call[]`).

import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import * as toml from "toml";

const abi = ethers.utils.defaultAbiCoder;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// `FixedForceDeploymentsData` bytecode-info slots → the contract whose ZKsync OS
// deployed bytecode they describe (mirrors
// `CoreOnGatewayHelper._resolveContractName(isZKsyncOS=true, ...)`). Each slot is
// `abi.encode(implInfo, proxyInfo)`; only the implementation is the contract
// below (the proxy is the shared `SystemContractProxy`).
const FFD_SLOT_CONTRACTS: Array<{ field: string; contract: string }> = [
  { field: "bridgehubBytecodeInfo", contract: "l1-contracts/L2Bridgehub" },
  { field: "l2AssetRouterBytecodeInfo", contract: "l1-contracts/L2AssetRouter" },
  { field: "l2NtvBytecodeInfo", contract: "l1-contracts/L2NativeTokenVaultZKOS" },
  { field: "messageRootBytecodeInfo", contract: "l1-contracts/L2MessageRoot" },
  { field: "chainAssetHandlerBytecodeInfo", contract: "l1-contracts/L2ChainAssetHandler" },
  { field: "interopCenterBytecodeInfo", contract: "l1-contracts/InteropCenter" },
  { field: "interopHandlerBytecodeInfo", contract: "l1-contracts/InteropHandler" },
  { field: "assetTrackerBytecodeInfo", contract: "l1-contracts/L2AssetTracker" },
  { field: "beaconDeployerInfo", contract: "l1-contracts/UpgradeableBeaconDeployer" },
  { field: "baseTokenHolderBytecodeInfo", contract: "l1-contracts/BaseTokenHolder" },
];

const V31_UPGRADE_CONTRACT = "l1-contracts/L2V31Upgrade";

// `ContractUpgradeType.ZKsyncOSUnsafeForceDeployment`.
const UPGRADE_TYPE_ZKSYNCOS_UNSAFE_FORCE_DEPLOYMENT = 2;

const REPO_ROOT = path.resolve(__dirname, "..", "..");
const DEFAULT_HASHES = path.join(REPO_ROOT, "AllContractsHashes.json");
const DEFAULT_ECOSYSTEM = path.join(
  REPO_ROOT,
  "l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml"
);
const DEFAULT_PATCH = path.join(
  REPO_ROOT,
  "l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/zkos-asset-tracker-patch.toml"
);
// Canonical ZKsync OS genesis (regenerated in this PR). Its `genesis_root` is the
// new chain-creation genesis batch hash — the genesis-only contracts changed by
// #2224 (L2ComplexUpgrader / L2GenesisUpgrade, transitively via L2AssetTracker)
// shift it. We can only read it (a state root, not bytecode), not recompute it.
const DEFAULT_GENESIS = path.join(REPO_ROOT, "configs/genesis/zksync-os/latest.json");

// ---------------------------------------------------------------------------
// ABI type descriptors (encoding-only, no contract ABIs are declared)
// ---------------------------------------------------------------------------

const DIAMOND_CUT_DATA =
  "tuple(tuple(address facet,uint8 action,bool isFreezable,bytes4[] selectors)[] facetCuts,address initAddress,bytes initCalldata)";

const FIXED_FORCE_DEPLOYMENTS_DATA =
  "tuple(uint256 l1ChainId,uint256 gatewayChainId,uint256 eraChainId,address l1AssetRouter,bytes32 l2TokenProxyBytecodeHash," +
  "address aliasedL1Governance,uint256 maxNumberOfZKChains,bytes bridgehubBytecodeInfo,bytes l2AssetRouterBytecodeInfo," +
  "bytes l2NtvBytecodeInfo,bytes messageRootBytecodeInfo,bytes chainAssetHandlerBytecodeInfo,bytes interopCenterBytecodeInfo," +
  "bytes interopHandlerBytecodeInfo,bytes assetTrackerBytecodeInfo,bytes beaconDeployerInfo,bytes baseTokenHolderBytecodeInfo," +
  "address l2SharedBridgeLegacyImpl,address l2BridgedStandardERC20Impl,address aliasedChainRegistrationSender," +
  "address dangerousTestOnlyForcedBeacon,bytes32 zkTokenAssetId)";

const UNIVERSAL_CONTRACT_UPGRADE_INFO = "tuple(uint8 upgradeType,bytes deployedBytecodeInfo,address newAddress)";

const CHAIN_CREATION_PARAMS =
  "tuple(address genesisUpgrade,bytes32 genesisBatchHash,uint64 genesisIndexRepeatedStorageChanges," +
  `bytes32 genesisBatchCommitment,${DIAMOND_CUT_DATA} diamondCut,bytes forceDeploymentsData)`;

const CALL = "tuple(address target,uint256 value,bytes data)";

// `NewChainCreationParams` (un-indexed) event payload.
const NEW_CHAIN_CREATION_PARAMS_EVENT = [
  "address",
  "bytes32",
  "uint64",
  "bytes32",
  DIAMOND_CUT_DATA,
  "bytes32",
  "bytes",
  "bytes32",
];

function selector(sig: string): string {
  return ethers.utils.id(sig).slice(0, 10);
}

const SIG_SET_CHAIN_CREATION_PARAMS =
  "setChainCreationParams((address,bytes32,uint64,bytes32,((address,uint8,bool,bytes4[])[],address,bytes),bytes))";
const SIG_SET_UPGRADE_DIAMOND_CUT = "setUpgradeDiamondCut(((address,uint8,bool,bytes4[])[],address,bytes),uint256)";

const TOPIC_NEW_CHAIN_CREATION_PARAMS = ethers.utils.id(
  "NewChainCreationParams(address,bytes32,uint64,bytes32,((address,uint8,bool,bytes4[])[],address,bytes),bytes32,bytes,bytes32)"
);
const TOPIC_NEW_UPGRADE_CUT_DATA = ethers.utils.id(
  "NewUpgradeCutData(uint256,((address,uint8,bool,bytes4[])[],address,bytes))"
);
const TOPIC_NEW_PROTOCOL_VERSION = ethers.utils.id("NewProtocolVersion(uint256,uint256)");

// ---------------------------------------------------------------------------
// Bytecode descriptors
// ---------------------------------------------------------------------------

interface ZkosBytecodeInfo {
  blake: string;
  length: number;
  keccak: string;
}

function decodeZkosBytecodeInfo(infoHex: string): ZkosBytecodeInfo {
  const [blake, length, keccak] = abi.decode(["bytes32", "uint32", "bytes32"], infoHex);
  return { blake, length: Number(length), keccak };
}

function encodeZkosBytecodeInfo(info: ZkosBytecodeInfo): string {
  return abi.encode(["bytes32", "uint32", "bytes32"], [info.blake, info.length, info.keccak]);
}

// `generateRandomAddress` (contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol).
function generateRandomAddress(bytecodeInfoHex: string): string {
  const hash = ethers.utils.keccak256(ethers.utils.hexConcat([ethers.constants.HashZero, bytecodeInfoHex]));
  return ethers.utils.getAddress("0x" + hash.slice(-40));
}

function infoFromHashesJson(entry: HashEntry): ZkosBytecodeInfo {
  if (
    !entry.evmDeployedBytecodeBlakeHash ||
    !entry.evmDeployedBytecodeHash ||
    entry.evmDeployedBytecodeLength == null
  ) {
    throw new Error(`Missing EVM deployed bytecode hashes for ${entry.contractName}`);
  }
  return {
    blake: entry.evmDeployedBytecodeBlakeHash,
    length: entry.evmDeployedBytecodeLength,
    keccak: entry.evmDeployedBytecodeHash,
  };
}

// ---------------------------------------------------------------------------
// AllContractsHashes.json
// ---------------------------------------------------------------------------

interface HashEntry {
  contractName: string;
  evmDeployedBytecodeHash: string | null;
  evmDeployedBytecodeBlakeHash: string | null;
  evmDeployedBytecodeLength: number | null;
}

function loadHashes(filePath: string): Map<string, HashEntry> {
  const arr: HashEntry[] = JSON.parse(fs.readFileSync(filePath, "utf8"));
  return new Map(arr.map((e) => [e.contractName, e]));
}

function allKnownKeccaks(hashes: Map<string, HashEntry>): Set<string> {
  const set = new Set<string>();
  for (const e of hashes.values()) {
    if (e.evmDeployedBytecodeHash && e.evmDeployedBytecodeHash !== "0x") {
      set.add(e.evmDeployedBytecodeHash.toLowerCase());
    }
  }
  return set;
}

// ---------------------------------------------------------------------------
// Hex helpers
// ---------------------------------------------------------------------------

function strip0x(s: string): string {
  return s.toLowerCase().replace(/^0x/, "");
}

function eqHex(a: string, b: string): boolean {
  return strip0x(a) === strip0x(b);
}

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`CHECK FAILED: ${msg}`);
}

// ---------------------------------------------------------------------------
// Structural decoding (to locate descriptors that should have changed)
// ---------------------------------------------------------------------------

function readFfdSlotImplInfo(ffdHex: string, field: string): ZkosBytecodeInfo {
  const [ffd] = abi.decode([FIXED_FORCE_DEPLOYMENTS_DATA], ffdHex);
  const [implInfo] = abi.decode(["bytes", "bytes"], ffd[field]);
  return decodeZkosBytecodeInfo(implInfo);
}

function findV31DelegateInfo(chainUpgradeDiamondCutHex: string): ZkosBytecodeInfo {
  const [dcd] = abi.decode([DIAMOND_CUT_DATA], chainUpgradeDiamondCutHex);
  // initCalldata = DefaultUpgrade.upgrade(ProposedUpgrade); the L2 tx `data`
  // (forceDeployAndUpgradeUniversal) is nested — locate the single
  // ZKsyncOSUnsafeForceDeployment entry inside it.
  const initCalldata: string = dcd.initCalldata;
  const PROPOSED_UPGRADE =
    "tuple(tuple(uint256 txType,uint256 from,uint256 to,uint256 gasLimit,uint256 gasPerPubdataByteLimit," +
    "uint256 maxFeePerGas,uint256 maxPriorityFeePerGas,uint256 paymaster,uint256 nonce,uint256 value,uint256[4] reserved," +
    "bytes data,bytes signature,uint256[] factoryDeps,bytes paymasterInput,bytes reservedDynamic) l2ProtocolUpgradeTx," +
    "bytes32 bootloaderHash,bytes32 defaultAccountHash,bytes32 evmEmulatorHash,address verifier," +
    "tuple(bytes32 a,bytes32 b,bytes32 c) verifierParams,bytes l1ContractsUpgradeCalldata,bytes postUpgradeCalldata," +
    "uint256 upgradeTimestamp,uint256 newProtocolVersion)";
  const [proposed] = abi.decode([PROPOSED_UPGRADE], "0x" + strip0x(initCalldata).slice(8));
  const [deployments] = abi.decode(
    [`${UNIVERSAL_CONTRACT_UPGRADE_INFO}[]`, "address", "bytes"],
    "0x" + strip0x(proposed.l2ProtocolUpgradeTx.data).slice(8)
  );
  const unsafe = deployments.filter(
    (d: { upgradeType: number }) => Number(d.upgradeType) === UPGRADE_TYPE_ZKSYNCOS_UNSAFE_FORCE_DEPLOYMENT
  );
  assert(unsafe.length === 1, `expected one ZKsyncOSUnsafeForceDeployment, found ${unsafe.length}`);
  return decodeZkosBytecodeInfo(unsafe[0].deployedBytecodeInfo);
}

// Every keccak referenced by the patched data must resolve to a current hash.
function collectFfdKeccaks(ffdHex: string): string[] {
  const [ffd] = abi.decode([FIXED_FORCE_DEPLOYMENTS_DATA], ffdHex);
  const keccaks: string[] = [];
  for (const { field } of FFD_SLOT_CONTRACTS) {
    const [implInfo, proxyInfo] = abi.decode(["bytes", "bytes"], ffd[field]);
    keccaks.push(decodeZkosBytecodeInfo(implInfo).keccak.toLowerCase());
    keccaks.push(decodeZkosBytecodeInfo(proxyInfo).keccak.toLowerCase());
  }
  return keccaks;
}

// ---------------------------------------------------------------------------
// Affected-contract detection + high-level byte substitution
// ---------------------------------------------------------------------------

interface Change {
  contract: string;
  old: ZkosBytecodeInfo;
  nw: ZkosBytecodeInfo;
  isV31: boolean;
}

// Compare every embedded descriptor (FFD slots + v31 delegate) of the ORIGINAL
// on-chain data against AllContractsHashes.json; whatever differs is a change.
function detectChanges(origFfd: string, origCut: string, hashes: Map<string, HashEntry>): Change[] {
  const changes: Change[] = [];
  for (const { field, contract } of FFD_SLOT_CONTRACTS) {
    const oldInfo = readFfdSlotImplInfo(origFfd, field);
    const e = hashes.get(contract);
    assert(!!e, `${contract} not present in AllContractsHashes.json`);
    const newInfo = infoFromHashesJson(e!);
    if (encodeZkosBytecodeInfo(oldInfo) !== encodeZkosBytecodeInfo(newInfo)) {
      changes.push({ contract, old: oldInfo, nw: newInfo, isV31: false });
    }
  }
  const v31Old = findV31DelegateInfo(origCut);
  const v31New = infoFromHashesJson(hashes.get(V31_UPGRADE_CONTRACT)!);
  if (encodeZkosBytecodeInfo(v31Old) !== encodeZkosBytecodeInfo(v31New)) {
    changes.push({ contract: V31_UPGRADE_CONTRACT, old: v31Old, nw: v31New, isV31: true });
  }
  return changes;
}

// Take the original blob and replace every substring that should have changed
// (the 96-byte descriptor, the standalone keccak in factoryDeps, and — for the
// v31 delegate — the derived `generateRandomAddress` address).
function expectedPatched(origBlobHex: string, changes: Change[]): string {
  let body = strip0x(origBlobHex);
  for (const c of changes) {
    body = body.split(strip0x(encodeZkosBytecodeInfo(c.old))).join(strip0x(encodeZkosBytecodeInfo(c.nw)));
    body = body.split(strip0x(c.old.keccak)).join(strip0x(c.nw.keccak));
    if (c.isV31) {
      const delOld = generateRandomAddress(encodeZkosBytecodeInfo(c.old));
      const delNew = generateRandomAddress(encodeZkosBytecodeInfo(c.nw));
      body = body.split(strip0x(delOld)).join(strip0x(delNew));
    }
  }
  return "0x" + body;
}

// ---------------------------------------------------------------------------
// On-chain queries
// ---------------------------------------------------------------------------

const WINDOW = 10_000;
const MAX_LOOKBACK = 5_000_000;

// Scan backwards from `latest` in 10k-block windows; return the highest-block
// log matching `topics`, or throw. (Per repo guidance we never scan from 0.)
async function latestLog(
  provider: ethers.providers.Provider,
  address: string,
  topics: Array<string | null>
): Promise<ethers.providers.Log> {
  const latest = await provider.getBlockNumber();
  const floor = Math.max(0, latest - MAX_LOOKBACK);
  for (let to = latest; to >= floor; to -= WINDOW) {
    const from = Math.max(floor, to - WINDOW + 1);
    const logs = await provider.getLogs({ address, topics, fromBlock: from, toBlock: to });
    if (logs.length > 0) return logs[logs.length - 1];
  }
  throw new Error(`no log with topic ${topics[0]} on ${address} in the last ${MAX_LOOKBACK} blocks`);
}

interface OnChainOriginal {
  protocolVersion: ethers.BigNumber;
  oldProtocolVersion: ethers.BigNumber;
  genesisUpgrade: string;
  genesisBatchHash: string;
  genesisIndexRepeatedStorageChanges: ethers.BigNumber;
  genesisBatchCommitment: string;
  diamondCut: unknown; // decoded DiamondCutData tuple
  forceDeploymentsData: string;
  upgradeCutData: string; // abi.encode(DiamondCutData), as emitted
}

async function fetchOnChainOriginal(provider: ethers.providers.Provider, ctm: string): Promise<OnChainOriginal> {
  const protocolVersion = ethers.BigNumber.from(await provider.call({ to: ctm, data: selector("protocolVersion()") }));

  // Latest protocol-version transition gives the (old -> new) versions.
  const npv = await latestLog(provider, ctm, [TOPIC_NEW_PROTOCOL_VERSION]);
  const oldProtocolVersion = ethers.BigNumber.from(npv.topics[1]);
  const newProtocolVersion = ethers.BigNumber.from(npv.topics[2]);
  assert(newProtocolVersion.eq(protocolVersion), "latest NewProtocolVersion.new != on-chain protocolVersion()");

  // Current chain-creation params.
  const ccpLog = await latestLog(provider, ctm, [TOPIC_NEW_CHAIN_CREATION_PARAMS]);
  const ccp = abi.decode(NEW_CHAIN_CREATION_PARAMS_EVENT, ccpLog.data);

  // The upgrade cut stored for the old protocol version (the one chains upgrade
  // FROM). `NewUpgradeCutData`'s protocolVersion is indexed (topic1). The event
  // payload is a single non-indexed DiamondCutData, so `log.data` is exactly
  // abi.encode(DiamondCutData) — the same encoding as `chain_upgrade_diamond_cut`.
  const cutLog = await latestLog(provider, ctm, [
    TOPIC_NEW_UPGRADE_CUT_DATA,
    ethers.utils.hexZeroPad(oldProtocolVersion.toHexString(), 32),
  ]);

  return {
    protocolVersion,
    oldProtocolVersion,
    genesisUpgrade: ccp[0],
    genesisBatchHash: ccp[1],
    genesisIndexRepeatedStorageChanges: ethers.BigNumber.from(ccp[2]),
    genesisBatchCommitment: ccp[3],
    diamondCut: ccp[4],
    forceDeploymentsData: ccp[6],
    upgradeCutData: cutLog.data,
  };
}

// ---------------------------------------------------------------------------
// Patch proposal TOML
// ---------------------------------------------------------------------------

function readPatch(filePath: string) {
  const zk = toml.parse(fs.readFileSync(filePath, "utf8")).zksync_os;
  if (!zk) throw new Error(`${filePath} has no [zksync_os] table`);
  return zk;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const hashesPath = process.env.HASHES_JSON || DEFAULT_HASHES;
  const ecosystemPath = process.env.ECOSYSTEM_TOML || DEFAULT_ECOSYSTEM;
  const patchPath = process.env.PATCH_TOML || DEFAULT_PATCH;
  const genesisPath = process.env.GENESIS_JSON || DEFAULT_GENESIS;
  const rpcUrl = process.env.L1_RPC || process.env.TENDERLY_SEPOLIA;
  if (!rpcUrl) throw new Error("Set L1_RPC (or TENDERLY_SEPOLIA) to the L1 RPC of the CTM's chain");

  console.log("Verifying ZKsync OS CTM patch proposal (hashes-only, on-chain-sourced)");
  console.log(`  hashes:     ${hashesPath}`);
  console.log(`  ecosystem:  ${ecosystemPath} (CTM address only)`);
  console.log(`  genesis:    ${genesisPath} (genesis root only)`);
  console.log(`  patch:      ${patchPath}`);

  const hashes = loadHashes(hashesPath);
  const known = allKnownKeccaks(hashes);

  // ONLY the CTM address comes from the ecosystem output.
  const ctm: string = toml.parse(fs.readFileSync(ecosystemPath, "utf8")).ctms.zksync_os.state_transition
    .chain_type_manager_proxy;
  console.log(`  ZKsync OS ChainTypeManager: ${ctm}`);

  // Original data straight from the CTM's on-chain events.
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const orig = await fetchOnChainOriginal(provider, ctm);
  console.log(`  on-chain protocolVersion: ${orig.protocolVersion} (old: ${orig.oldProtocolVersion})`);

  const patch = readPatch(patchPath);
  assert(
    ethers.utils.getAddress(patch.chain_type_manager) === ethers.utils.getAddress(ctm),
    "patch CTM != ecosystem CTM"
  );

  // --- what changed (vs the on-chain originals) ---
  const changes = detectChanges(orig.forceDeploymentsData, orig.upgradeCutData, hashes);
  assert(changes.length > 0, "no affected descriptors detected on-chain vs AllContractsHashes.json");
  console.log(`  detected ${changes.length} changed descriptor(s):`);
  for (const c of changes) {
    console.log(`    ${c.contract}: ${c.old.keccak} -> ${c.nw.keccak}`);
  }

  // --- (1) data differs from on-chain originals ONLY in the changed substrings ---
  assert(
    eqHex(expectedPatched(orig.forceDeploymentsData, changes), patch.force_deployments_data),
    "force_deployments_data is not the on-chain original with only the changed bytecode descriptors substituted"
  );
  assert(
    eqHex(expectedPatched(orig.upgradeCutData, changes), patch.chain_upgrade_diamond_cut),
    "chain_upgrade_diamond_cut is not the on-chain original with only the changed descriptors substituted"
  );
  // The chain-creation diamond cut must be byte-identical to on-chain (untouched).
  assert(eqHex(abi.encode([DIAMOND_CUT_DATA], [orig.diamondCut]), patch.diamond_cut_data), "diamond_cut_data changed");

  // --- (1b) completeness: every reference in the patched data is a current hash ---
  for (const k of collectFfdKeccaks(patch.force_deployments_data)) {
    assert(known.has(k), `force_deployments_data references unknown bytecode hash ${k}`);
  }

  // --- (2) the ChainTypeManager calls were constructed correctly ---
  // setChainCreationParams: original params with `forceDeploymentsData` swapped to
  // the patched value and `genesisBatchHash` bumped to the regenerated genesis root
  // (the genesis-only contracts changed by #2224 shift it).
  assert(
    strip0x(patch.set_chain_creation_params_calldata).startsWith(strip0x(selector(SIG_SET_CHAIN_CREATION_PARAMS))),
    "set_chain_creation_params_calldata has the wrong selector"
  );
  const [ccpArg] = abi.decode(
    [CHAIN_CREATION_PARAMS],
    "0x" + strip0x(patch.set_chain_creation_params_calldata).slice(8)
  );
  assert(
    ethers.utils.getAddress(ccpArg.genesisUpgrade) === ethers.utils.getAddress(orig.genesisUpgrade),
    "genesisUpgrade changed"
  );
  // genesisBatchHash MUST move from the on-chain value to the regenerated genesis
  // root (a state root, not bytecode, so we read it from the canonical genesis file
  // rather than recompute it).
  const newGenesisRoot: string = JSON.parse(fs.readFileSync(genesisPath, "utf8")).genesis_root;
  assert(eqHex(ccpArg.genesisBatchHash, newGenesisRoot), "genesisBatchHash != regenerated genesis root");
  assert(!eqHex(newGenesisRoot, orig.genesisBatchHash), "genesis root unchanged vs on-chain — expected it to move");
  assert(
    ethers.BigNumber.from(ccpArg.genesisIndexRepeatedStorageChanges).eq(orig.genesisIndexRepeatedStorageChanges),
    "genesisIndex changed"
  );
  assert(eqHex(ccpArg.genesisBatchCommitment, orig.genesisBatchCommitment), "genesisBatchCommitment changed");
  assert(
    eqHex(abi.encode([DIAMOND_CUT_DATA], [ccpArg.diamondCut]), patch.diamond_cut_data),
    "ccp.diamondCut != on-chain diamond cut"
  );
  assert(
    eqHex(ccpArg.forceDeploymentsData, patch.force_deployments_data),
    "ccp.forceDeploymentsData != patched force deployments"
  );

  // setUpgradeDiamondCut: the patched cut + the old protocol version.
  assert(
    strip0x(patch.set_upgrade_diamond_cut_calldata).startsWith(strip0x(selector(SIG_SET_UPGRADE_DIAMOND_CUT))),
    "set_upgrade_diamond_cut_calldata has the wrong selector"
  );
  const [cutArg, oldVerArg] = abi.decode(
    [DIAMOND_CUT_DATA, "uint256"],
    "0x" + strip0x(patch.set_upgrade_diamond_cut_calldata).slice(8)
  );
  assert(
    eqHex(abi.encode([DIAMOND_CUT_DATA], [cutArg]), patch.chain_upgrade_diamond_cut),
    "setUpgradeDiamondCut cut != patched upgrade cut"
  );
  assert(
    ethers.BigNumber.from(oldVerArg).eq(orig.oldProtocolVersion),
    "setUpgradeDiamondCut old version != on-chain old protocol version"
  );

  // governance_calls = abi.encode([setChainCreationParams, setUpgradeDiamondCut]) at the CTM.
  const [calls] = abi.decode([`${CALL}[]`], patch.governance_calls);
  assert(calls.length === 2, `expected 2 governance calls, found ${calls.length}`);
  assert(ethers.utils.getAddress(calls[0].target) === ethers.utils.getAddress(ctm), "call0 target != CTM");
  assert(ethers.utils.getAddress(calls[1].target) === ethers.utils.getAddress(ctm), "call1 target != CTM");
  assert(eqHex(calls[0].data, patch.set_chain_creation_params_calldata), "call0 != setChainCreationParams calldata");
  assert(eqHex(calls[1].data, patch.set_upgrade_diamond_cut_calldata), "call1 != setUpgradeDiamondCut calldata");

  console.log("\nAll checks passed:");
  console.log("  - chain-creation params / upgrade data differ from the on-chain originals");
  console.log("    only in the bytecode descriptors that AllContractsHashes.json says changed;");
  console.log(
    `  - genesisBatchHash bumped on-chain ${orig.genesisBatchHash} -> ${newGenesisRoot} (regenerated genesis root);`
  );
  console.log("  - setChainCreationParams + setUpgradeDiamondCut calls are correctly constructed.");
}

main().catch((e) => {
  console.error(e.message || e);
  process.exit(1);
});
