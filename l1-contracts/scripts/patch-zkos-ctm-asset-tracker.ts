// SPDX-License-Identifier: MIT
//
// Patch (hashes-only) for the ZKsync OS chain type manager (CTM) upgrade data,
// motivated by https://github.com/matter-labs/era-contracts/pull/2224.
//
// PR #2224 changed the bytecode of `L2AssetTracker` (and, transitively, a few
// other contracts). The already-prepared v31 upgrade artifacts therefore embed
// stale ZKsync-OS bytecode descriptors for the ZKsync OS CTM. This script
// regenerates the affected CTM data (`force_deployments_data` and
// `chain_upgrade_diamond_cut`) for the ZKsync OS CTM ONLY.
//
// Unlike the forge counterpart (`PatchZkosCtmAssetTracker.s.sol`), which
// reconstructs the data from scratch out of the real compiled bytecode, this
// script NEVER touches the bytecode. It:
//   1. decodes the existing chain-creation params / upgrade data,
//   2. enumerates EVERY contract whose bytecode descriptor is embedded there
//      (all `FixedForceDeploymentsData` slots + the v31 upgrade delegate),
//   3. for each, rewrites the descriptor to the NEW hashes taken purely from
//      `AllContractsHashes.json` whenever it differs from the embedded one
//      (so any affected contract is updated, not just a hard-coded pair),
//   4. double-checks that every stale reference has been replaced and that the
//      patched data only references bytecodes whose hashes are present in
//      `AllContractsHashes.json`.
//
// The produced blobs are byte-for-byte identical to the ones reconstructed by
// the forge script, so running both and diffing the outputs validates that
// `AllContractsHashes.json` is consistent with the actual artifacts.

import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import * as toml from "toml";

const abi = ethers.utils.defaultAbiCoder;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// `FixedForceDeploymentsData` bytecode-info slots → the contract whose ZKsync OS
// deployed bytecode they describe. Resolution mirrors
// `CoreOnGatewayHelper._resolveContractName(isZKsyncOS=true, ...)`. Each slot is
// `abi.encode(implInfo, proxyInfo)`; only the implementation is the contract
// below (the proxy is the shared `SystemContractProxy`, untouched here).
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

// The v31 upgrade delegate, force-deployed via the single
// `ZKsyncOSUnsafeForceDeployment` entry in the upgrade transaction.
const V31_UPGRADE_CONTRACT = "l1-contracts/L2V31Upgrade";

// `ContractUpgradeType` enum (contracts/state-transition/l2-deps/IComplexUpgrader.sol)
const UPGRADE_TYPE_ZKSYNCOS_UNSAFE_FORCE_DEPLOYMENT = 2;

const REPO_ROOT = path.resolve(__dirname, "..", "..");
const DEFAULT_HASHES = path.join(REPO_ROOT, "AllContractsHashes.json");
const DEFAULT_ECOSYSTEM = path.join(
  REPO_ROOT,
  "l1-contracts/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml"
);
const DEFAULT_OUTPUT = path.join(REPO_ROOT, "l1-contracts/script-out/zkos-ctm-asset-tracker-patch.ts.json");

// ---------------------------------------------------------------------------
// ABI type descriptors (encoding-only, no contract ABIs are declared)
// ---------------------------------------------------------------------------

const DIAMOND_CUT_DATA =
  "tuple(tuple(address facet,uint8 action,bool isFreezable,bytes4[] selectors)[] facetCuts,address initAddress,bytes initCalldata)";

const L2_CANONICAL_TX =
  "tuple(uint256 txType,uint256 from,uint256 to,uint256 gasLimit,uint256 gasPerPubdataByteLimit,uint256 maxFeePerGas," +
  "uint256 maxPriorityFeePerGas,uint256 paymaster,uint256 nonce,uint256 value,uint256[4] reserved,bytes data,bytes signature," +
  "uint256[] factoryDeps,bytes paymasterInput,bytes reservedDynamic)";

const PROPOSED_UPGRADE =
  `tuple(${L2_CANONICAL_TX} l2ProtocolUpgradeTx,bytes32 bootloaderHash,bytes32 defaultAccountHash,bytes32 evmEmulatorHash,` +
  "address verifier,tuple(bytes32 recursionNodeLevelVkHash,bytes32 recursionLeafLevelVkHash,bytes32 recursionCircuitsSetVksHash) verifierParams," +
  "bytes l1ContractsUpgradeCalldata,bytes postUpgradeCalldata,uint256 upgradeTimestamp,uint256 newProtocolVersion)";

const FIXED_FORCE_DEPLOYMENTS_DATA =
  "tuple(uint256 l1ChainId,uint256 gatewayChainId,uint256 eraChainId,address l1AssetRouter,bytes32 l2TokenProxyBytecodeHash," +
  "address aliasedL1Governance,uint256 maxNumberOfZKChains,bytes bridgehubBytecodeInfo,bytes l2AssetRouterBytecodeInfo," +
  "bytes l2NtvBytecodeInfo,bytes messageRootBytecodeInfo,bytes chainAssetHandlerBytecodeInfo,bytes interopCenterBytecodeInfo," +
  "bytes interopHandlerBytecodeInfo,bytes assetTrackerBytecodeInfo,bytes beaconDeployerInfo,bytes baseTokenHolderBytecodeInfo," +
  "address l2SharedBridgeLegacyImpl,address l2BridgedStandardERC20Impl,address aliasedChainRegistrationSender," +
  "address dangerousTestOnlyForcedBeacon,bytes32 zkTokenAssetId)";

const UNIVERSAL_CONTRACT_UPGRADE_INFO = "tuple(uint8 upgradeType,bytes deployedBytecodeInfo,address newAddress)";

// ---------------------------------------------------------------------------
// Bytecode descriptors
// ---------------------------------------------------------------------------

// A ZKsync OS bytecode descriptor: abi.encode(bytes32 blake2s, uint32 length, bytes32 keccak).
// See contracts/common/libraries/ZKSyncOSBytecodeInfo.sol.
interface ZkosBytecodeInfo {
  blake: string; // 0x-prefixed bytes32
  length: number;
  keccak: string; // 0x-prefixed bytes32
}

function decodeZkosBytecodeInfo(infoHex: string): ZkosBytecodeInfo {
  const [blake, length, keccak] = abi.decode(["bytes32", "uint32", "bytes32"], infoHex);
  return { blake, length: Number(length), keccak };
}

function encodeZkosBytecodeInfo(info: ZkosBytecodeInfo): string {
  return abi.encode(["bytes32", "uint32", "bytes32"], [info.blake, info.length, info.keccak]);
}

// `generateRandomAddress` from contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol:
// address(uint160(uint256(keccak256(bytes.concat(bytes32(0), bytecodeInfo))))).
function generateRandomAddress(bytecodeInfoHex: string): string {
  const packed = ethers.utils.hexConcat([ethers.constants.HashZero, bytecodeInfoHex]);
  const hash = ethers.utils.keccak256(packed);
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
  const map = new Map<string, HashEntry>();
  for (const e of arr) {
    map.set(e.contractName, e);
  }
  return map;
}

// Every keccak hash referenced by the patched data must resolve to one of these.
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
// Hex helpers (byte-accurate, layout-preserving substitution)
// ---------------------------------------------------------------------------

function strip0x(s: string): string {
  return s.toLowerCase().replace(/^0x/, "");
}

function countOccurrences(haystack: string, needle: string): number {
  let count = 0;
  let idx = haystack.indexOf(needle);
  while (idx !== -1) {
    count++;
    idx = haystack.indexOf(needle, idx + needle.length);
  }
  return count;
}

// Replaces every occurrence of `oldHex` with `newHex` (equal length) in a
// 0x-prefixed blob, returning the new blob and the number of replacements.
// Equal lengths keep every ABI offset intact (only descriptor contents change).
function replaceAll(blobHex: string, oldHex: string, newHex: string): { blob: string; count: number } {
  if (oldHex.length !== newHex.length) {
    throw new Error("substitution length mismatch (layout would break)");
  }
  const body = strip0x(blobHex);
  const count = countOccurrences(body, oldHex);
  return { blob: "0x" + body.split(oldHex).join(newHex), count };
}

// ---------------------------------------------------------------------------
// Structural decoding of the ZKsync OS CTM data
// ---------------------------------------------------------------------------

// Returns the implementation descriptor stored in a `FixedForceDeploymentsData`
// bytecode-info slot (each slot is abi.encode(implInfo, proxyInfo)).
function readFfdSlotImplInfo(ffdHex: string, field: string): ZkosBytecodeInfo {
  const [ffd] = abi.decode([FIXED_FORCE_DEPLOYMENTS_DATA], ffdHex);
  const [implInfo] = abi.decode(["bytes", "bytes"], ffd[field]);
  return decodeZkosBytecodeInfo(implInfo);
}

interface UpgradeCutParts {
  deployments: Array<{ upgradeType: number; deployedBytecodeInfo: string; newAddress: string }>;
  delegateTo: string;
  innerForceDeploymentsData: string;
  factoryDeps: string[]; // 0x-prefixed bytes32 keccak hashes
}

function decodeUpgradeCut(chainUpgradeDiamondCutHex: string): UpgradeCutParts {
  const [dcd] = abi.decode([DIAMOND_CUT_DATA], chainUpgradeDiamondCutHex);
  // initCalldata = DefaultUpgrade.upgrade(ProposedUpgrade) -> strip 4-byte selector.
  const [proposedUpgrade] = abi.decode([PROPOSED_UPGRADE], "0x" + strip0x(dcd.initCalldata).slice(8));
  const tx = proposedUpgrade.l2ProtocolUpgradeTx;
  const factoryDeps: string[] = tx.factoryDeps.map((d: ethers.BigNumber) =>
    ethers.utils.hexZeroPad(d.toHexString(), 32)
  );
  // tx.data = forceDeployAndUpgradeUniversal(deployments, delegateTo, innerCalldata).
  const txDataBody = "0x" + strip0x(tx.data).slice(8);
  const [deploymentsRaw, delegateTo, inner] = abi.decode(
    [`${UNIVERSAL_CONTRACT_UPGRADE_INFO}[]`, "address", "bytes"],
    txDataBody
  );
  const deployments = deploymentsRaw.map(
    (d: { upgradeType: number; deployedBytecodeInfo: string; newAddress: string }) => ({
      upgradeType: Number(d.upgradeType),
      deployedBytecodeInfo: d.deployedBytecodeInfo,
      newAddress: d.newAddress,
    })
  );
  // inner = IL2V31Upgrade.upgrade(bool, address, bytes forceDeploymentsData, bytes) -> strip selector.
  const [, , innerForceDeploymentsData] = abi.decode(
    ["bool", "address", "bytes", "bytes"],
    "0x" + strip0x(inner).slice(8)
  );
  return { deployments, delegateTo, innerForceDeploymentsData, factoryDeps };
}

function findV31DelegateInfo(parts: UpgradeCutParts): ZkosBytecodeInfo {
  const unsafe = parts.deployments.filter((d) => d.upgradeType === UPGRADE_TYPE_ZKSYNCOS_UNSAFE_FORCE_DEPLOYMENT);
  if (unsafe.length !== 1) {
    throw new Error(`Expected exactly one ZKsyncOSUnsafeForceDeployment (v31 delegate), found ${unsafe.length}`);
  }
  return decodeZkosBytecodeInfo(unsafe[0].deployedBytecodeInfo);
}

// Collect every keccak hash referenced by a force-deployments blob (each
// `*BytecodeInfo` may be a single descriptor or an abi.encode(impl, proxy) pair).
function collectFfdKeccaks(ffdHex: string): string[] {
  const [ffd] = abi.decode([FIXED_FORCE_DEPLOYMENTS_DATA], ffdHex);
  const keccaks: string[] = [];
  for (const { field } of FFD_SLOT_CONTRACTS) {
    const value: string = ffd[field];
    if (!value || strip0x(value).length === 0) continue;
    const [implInfo, proxyInfo] = abi.decode(["bytes", "bytes"], value);
    keccaks.push(decodeZkosBytecodeInfo(implInfo).keccak.toLowerCase());
    keccaks.push(decodeZkosBytecodeInfo(proxyInfo).keccak.toLowerCase());
  }
  return keccaks;
}

// Collect every keccak hash referenced by the upgrade-cut blob.
function collectUpgradeCutKeccaks(chainUpgradeDiamondCutHex: string): string[] {
  const parts = decodeUpgradeCut(chainUpgradeDiamondCutHex);
  const keccaks: string[] = [];
  for (const dep of parts.deployments) {
    if (dep.upgradeType === UPGRADE_TYPE_ZKSYNCOS_UNSAFE_FORCE_DEPLOYMENT) {
      keccaks.push(decodeZkosBytecodeInfo(dep.deployedBytecodeInfo).keccak.toLowerCase());
    } else {
      const [implInfo, proxyInfo] = abi.decode(["bytes", "bytes"], dep.deployedBytecodeInfo);
      keccaks.push(decodeZkosBytecodeInfo(implInfo).keccak.toLowerCase());
      keccaks.push(decodeZkosBytecodeInfo(proxyInfo).keccak.toLowerCase());
    }
  }
  for (const fd of parts.factoryDeps) {
    keccaks.push(fd.toLowerCase());
  }
  keccaks.push(...collectFfdKeccaks(parts.innerForceDeploymentsData));
  return keccaks;
}

// Assert that every keccak referenced by the patched data resolves to a hash in
// AllContractsHashes.json. This is the strong "no stale reference left behind"
// completeness check: any contract whose bytecode changed but was missed would
// leave a keccak that is absent from the current hashes file.
function assertNoStaleReferences(label: string, keccaks: string[], known: Set<string>): void {
  const stale = keccaks.filter((k) => !known.has(k));
  if (stale.length > 0) {
    throw new Error(
      `${label}: ${stale.length} stale bytecode reference(s) not present in AllContractsHashes.json: ${[
        ...new Set(stale),
      ].join(", ")}`
    );
  }
}

// ---------------------------------------------------------------------------
// TOML helpers
// ---------------------------------------------------------------------------

function readEcosystem(filePath: string): {
  forceDeploymentsData: string;
  chainUpgradeDiamondCut: string;
  diamondCutData: string;
} {
  const parsed = toml.parse(fs.readFileSync(filePath, "utf8"));
  const zk = parsed?.ctms?.zksync_os;
  if (!zk) {
    throw new Error("ecosystem.toml has no [ctms.zksync_os] section");
  }
  return {
    forceDeploymentsData: zk.contracts_config.force_deployments_data,
    chainUpgradeDiamondCut: zk.chain_upgrade_diamond_cut,
    diamondCutData: zk.contracts_config.diamond_cut_data,
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

interface Change {
  contract: string;
  old: ZkosBytecodeInfo;
  nw: ZkosBytecodeInfo;
  isV31: boolean;
}

function main() {
  const hashesPath = process.env.HASHES_JSON || DEFAULT_HASHES;
  const ecosystemPath = process.env.ECOSYSTEM_TOML || DEFAULT_ECOSYSTEM;
  const outputPath = process.env.PATCH_OUTPUT || DEFAULT_OUTPUT;

  console.log("Patching ZKsync OS CTM upgrade data (hashes-only, TS)");
  console.log(`  hashes:     ${hashesPath}`);
  console.log(`  ecosystem:  ${ecosystemPath}`);
  console.log(`  output:     ${outputPath}`);

  const hashes = loadHashes(hashesPath);
  const known = allKnownKeccaks(hashes);
  const eco = readEcosystem(ecosystemPath);

  // --- detect every contract whose embedded descriptor differs from the hashes ---
  const changes: Change[] = [];
  const requireEntry = (contract: string): HashEntry => {
    const e = hashes.get(contract);
    if (!e) throw new Error(`${contract} not present in AllContractsHashes.json`);
    return e;
  };

  // All FixedForceDeploymentsData slots.
  for (const { field, contract } of FFD_SLOT_CONTRACTS) {
    const oldInfo = readFfdSlotImplInfo(eco.forceDeploymentsData, field);
    const newInfo = infoFromHashesJson(requireEntry(contract));
    if (encodeZkosBytecodeInfo(oldInfo) !== encodeZkosBytecodeInfo(newInfo)) {
      changes.push({ contract, old: oldInfo, nw: newInfo, isV31: false });
    }
  }

  // The v31 upgrade delegate.
  const upgradeParts = decodeUpgradeCut(eco.chainUpgradeDiamondCut);
  {
    const oldInfo = findV31DelegateInfo(upgradeParts);
    const newInfo = infoFromHashesJson(requireEntry(V31_UPGRADE_CONTRACT));
    if (encodeZkosBytecodeInfo(oldInfo) !== encodeZkosBytecodeInfo(newInfo)) {
      changes.push({ contract: V31_UPGRADE_CONTRACT, old: oldInfo, nw: newInfo, isV31: true });
    }
    // Sanity: the asset tracker descriptor in the embedded force deployments data
    // must match the standalone one.
    const atField = FFD_SLOT_CONTRACTS.find((s) => s.contract === "l1-contracts/L2AssetTracker")!.field;
    const a = readFfdSlotImplInfo(eco.forceDeploymentsData, atField);
    const b = readFfdSlotImplInfo(upgradeParts.innerForceDeploymentsData, atField);
    if (encodeZkosBytecodeInfo(a) !== encodeZkosBytecodeInfo(b)) {
      throw new Error("Asset tracker descriptor differs between force-deployments data and upgrade cut");
    }
  }

  if (changes.length === 0) {
    throw new Error("No affected descriptors found — input already patched, or no bytecode changed?");
  }
  console.log(`  detected ${changes.length} affected contract(s):`);
  for (const c of changes) {
    console.log(`    ${c.contract}: ${c.old.keccak} (len ${c.old.length}) -> ${c.nw.keccak} (len ${c.nw.length})`);
  }

  // --- v31 delegate address is derived from its descriptor ---
  let delegateOld = "";
  let delegateNew = "";
  const v31 = changes.find((c) => c.isV31);
  if (v31) {
    delegateOld = generateRandomAddress(encodeZkosBytecodeInfo(v31.old));
    delegateNew = generateRandomAddress(encodeZkosBytecodeInfo(v31.nw));
    if (ethers.utils.getAddress(delegateOld) !== ethers.utils.getAddress(upgradeParts.delegateTo)) {
      throw new Error("Recomputed old v31 delegate address does not match the decoded delegateTo");
    }
    console.log(`  v31 delegate ${delegateOld} -> ${delegateNew}`);
  }

  // --- apply the byte-level substitutions ---
  // For every affected contract: replace the 96-byte descriptor first (so the
  // keccak inside it is rewritten as part of the descriptor), then the standalone
  // keccak hashes (factoryDeps). Finally, the derived v31 delegate address.
  let forceDeploymentsDataNew = eco.forceDeploymentsData;
  let chainUpgradeDiamondCutNew = eco.chainUpgradeDiamondCut;

  const patchBlob = (blob: string, label: string): string => {
    let out = blob;
    for (const c of changes) {
      const desc = replaceAll(out, strip0x(encodeZkosBytecodeInfo(c.old)), strip0x(encodeZkosBytecodeInfo(c.nw)));
      out = desc.blob;
      const kec = replaceAll(out, strip0x(c.old.keccak), strip0x(c.nw.keccak));
      out = kec.blob;
    }
    if (label === "chain_upgrade_diamond_cut" && v31) {
      const del = replaceAll(out, strip0x(delegateOld), strip0x(delegateNew));
      if (del.count === 0) throw new Error("v31 delegate address not found in upgrade cut");
      out = del.blob;
    }
    return out;
  };

  forceDeploymentsDataNew = patchBlob(forceDeploymentsDataNew, "force_deployments_data");
  chainUpgradeDiamondCutNew = patchBlob(chainUpgradeDiamondCutNew, "chain_upgrade_diamond_cut");

  // --- double-check the result ---
  // 1. No old descriptor / keccak / blake / delegate address may survive.
  for (const [label, blob] of [
    ["force_deployments_data", forceDeploymentsDataNew],
    ["chain_upgrade_diamond_cut", chainUpgradeDiamondCutNew],
  ] as Array<[string, string]>) {
    const body = strip0x(blob);
    for (const c of changes) {
      for (const stale of [strip0x(c.old.keccak), strip0x(c.old.blake)]) {
        if (body.includes(stale)) {
          throw new Error(`${label}: stale reference ${stale} (${c.contract}) still present after patching`);
        }
      }
    }
    if (delegateOld && body.includes(strip0x(delegateOld))) {
      throw new Error(`${label}: stale v31 delegate ${delegateOld} still present after patching`);
    }
  }

  // 2. Every bytecode reference in the patched data resolves to a current hash.
  assertNoStaleReferences("force_deployments_data", collectFfdKeccaks(forceDeploymentsDataNew), known);
  assertNoStaleReferences("chain_upgrade_diamond_cut", collectUpgradeCutKeccaks(chainUpgradeDiamondCutNew), known);

  // 3. The chain-creation diamond cut embeds no such descriptor and is untouched.
  const diamondCutBody = strip0x(eco.diamondCutData);
  for (const c of changes) {
    if (diamondCutBody.includes(strip0x(c.nw.keccak)) || diamondCutBody.includes(strip0x(c.old.keccak))) {
      throw new Error(`diamond_cut_data unexpectedly references ${c.contract}`);
    }
  }

  const out = {
    source: {
      hashes: path.relative(REPO_ROOT, hashesPath),
      ecosystem: path.relative(REPO_ROOT, ecosystemPath),
    },
    ctm: "zksync_os",
    changedContracts: changes.map((c) => ({
      contract: c.contract,
      oldKeccak: c.old.keccak,
      newKeccak: c.nw.keccak,
      oldLength: c.old.length,
      newLength: c.nw.length,
    })),
    v31DelegateOld: delegateOld ? ethers.utils.getAddress(delegateOld) : null,
    v31DelegateNew: delegateNew ? ethers.utils.getAddress(delegateNew) : null,
    diamondCutDataUnchanged: eco.diamondCutData,
    forceDeploymentsData: forceDeploymentsDataNew,
    chainUpgradeDiamondCut: chainUpgradeDiamondCutNew,
  };

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(out, null, 2) + "\n");
  console.log(`\nAll checks passed. Patched ZKsync OS CTM data written to:\n  ${outputPath}`);

  // Optionally write a fully patched ecosystem.toml (the amended upgrade).
  // The old ZKsync OS `force_deployments_data` is a substring of the old
  // `chain_upgrade_diamond_cut`, so we replace the (longer) upgrade-cut value
  // first; afterwards the only remaining occurrence of the old force-deployments
  // value is its own standalone key.
  if (process.env.APPLY === "true") {
    const appliedPath = process.env.APPLY_OUTPUT || ecosystemPath.replace(/\.toml$/, ".patched.toml");
    const tomlText = fs.readFileSync(ecosystemPath, "utf8");

    // Restrict the replacement to the `[ctms.zksync_os]` section: the gateway
    // state transition (`[new_gateway...]`) shares the same force-deployments
    // blob, but it is a different CTM and is out of scope for this patch.
    const sectionStart = tomlText.indexOf("[ctms.zksync_os]");
    if (sectionStart === -1) {
      throw new Error("apply: [ctms.zksync_os] section not found");
    }
    // The section ends at the first top-level table that is not nested under it.
    const after = tomlText.slice(sectionStart + 1);
    const nextHeaderRel = after.search(/\n\[(?!ctms\.zksync_os)/);
    const sectionEnd = nextHeaderRel === -1 ? tomlText.length : sectionStart + 1 + nextHeaderRel;

    let section = tomlText.slice(sectionStart, sectionEnd);
    const replaceOnce = (label: string, oldVal: string, newVal: string) => {
      const occurrences = countOccurrences(section, oldVal);
      if (occurrences !== 1) {
        throw new Error(`apply: expected exactly one occurrence of ${label} in [ctms.zksync_os], found ${occurrences}`);
      }
      section = section.replace(oldVal, newVal);
    };
    replaceOnce("chain_upgrade_diamond_cut", eco.chainUpgradeDiamondCut, chainUpgradeDiamondCutNew);
    replaceOnce("force_deployments_data", eco.forceDeploymentsData, forceDeploymentsDataNew);

    const patchedText = tomlText.slice(0, sectionStart) + section + tomlText.slice(sectionEnd);
    fs.writeFileSync(appliedPath, patchedText);
    console.log(`Amended upgrade (zksync_os CTM only) written to:\n  ${appliedPath}`);
  }
}

main();
