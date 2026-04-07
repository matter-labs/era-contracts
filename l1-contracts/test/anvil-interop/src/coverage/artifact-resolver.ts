/**
 * Resolves deployed contract addresses to their compilation artifacts.
 *
 * Uses two strategies:
 * 1. Known addresses from the deployment state (fast, reliable)
 * 2. Bytecode matching against Forge artifacts (fallback for unknown addresses)
 *
 * Proxy handling:
 *   L1 contracts use ERC-1967 transparent proxies. The deployment state stores
 *   proxy addresses, but the actual implementation code lives at a different address.
 *   We resolve proxy -> implementation by reading the EIP-1967 storage slot,
 *   then register the implementation address with the same artifact. This ensures
 *   that PCs from DELEGATECALL execution (at depth 2+) are correctly attributed
 *   to the implementation contract's source map.
 */

import * as fs from "fs";
import * as path from "path";
import { providers } from "ethers";
import type { ContractSourceMap } from "./source-map-decoder";
import { loadContractSourceMap } from "./source-map-decoder";

export interface ResolvedContract {
  address: string;
  name: string;
  artifactPath: string;
  sourceMap: ContractSourceMap;
}

/**
 * ERC-1967 implementation storage slot.
 */
const EIP1967_IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

/**
 * Scans the Forge output directory for all contract artifacts.
 * Returns a map of normalized deployed bytecode prefix -> artifact path.
 */
function buildBytecodeIndex(outDir: string): Map<string, { artifactPath: string; fullBytecode: string }> {
  const index = new Map<string, { artifactPath: string; fullBytecode: string }>();
  const PREFIX_LENGTH = 64;

  const entries = fs.readdirSync(outDir, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name === "build-info") continue;

    const solDir = path.join(outDir, entry.name);
    const jsonFiles = fs.readdirSync(solDir).filter((f) => f.endsWith(".json"));

    for (const jsonFile of jsonFiles) {
      const artifactPath = path.join(solDir, jsonFile);
      try {
        const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
        const bytecode = artifact.deployedBytecode?.object;
        if (!bytecode || bytecode === "0x") continue;

        const hex = bytecode.startsWith("0x") ? bytecode.slice(2) : bytecode;
        if (hex.length < PREFIX_LENGTH) continue;

        const prefix = hex.slice(0, PREFIX_LENGTH).toLowerCase();
        if (!index.has(prefix)) {
          index.set(prefix, { artifactPath, fullBytecode: hex });
        }
      } catch {
        // Skip malformed artifacts
      }
    }
  }

  return index;
}

/**
 * Given deployed bytecode, finds the matching compilation artifact.
 */
function matchBytecode(
  deployedHex: string,
  bytecodeIndex: Map<string, { artifactPath: string; fullBytecode: string }>
): string | null {
  const PREFIX_LENGTH = 64;
  const hex = deployedHex.startsWith("0x") ? deployedHex.slice(2) : deployedHex;

  if (hex.length < PREFIX_LENGTH) return null;

  const prefix = hex.slice(0, PREFIX_LENGTH).toLowerCase();
  const match = bytecodeIndex.get(prefix);

  if (!match) return null;

  const compareLength = Math.min(hex.length, match.fullBytecode.length);
  const checkLength = Math.floor(compareLength * 0.8);

  if (hex.slice(0, checkLength).toLowerCase() === match.fullBytecode.slice(0, checkLength).toLowerCase()) {
    return match.artifactPath;
  }

  return null;
}

/** Maps well-known deployment field names to their likely contract artifact names. */
const KNOWN_CONTRACT_NAMES: Record<string, string[]> = {
  bridgehub: ["L1Bridgehub"],
  l1SharedBridge: ["L1AssetRouter"],
  l1NativeTokenVault: ["L1NativeTokenVault"],
  l1AssetTracker: ["L1AssetTracker"],
  l1Nullifier: ["L1Nullifier"],
  l1NullifierProxy: ["L1Nullifier"],
  stateTransitionProxy: ["ChainTypeManager"],
  chainTypeManager: ["ChainTypeManager"],
  diamondProxy: ["DiamondProxy"],
  messageRoot: ["MessageRoot"],
  ctmDeploymentTracker: ["CTMDeploymentTracker"],
  chainRegistrationSender: ["ChainRegistrationSender"],
  // Diamond facets
  adminFacet: ["AdminFacet"],
  gettersFacet: ["GettersFacet"],
  mailboxFacet: ["MailboxFacet"],
  executorFacet: ["ExecutorFacet"],
  migratorFacet: ["MigratorFacet"],
};

/**
 * Attempts to find the artifact for a contract by name.
 */
function findArtifactByName(outDir: string, contractName: string): string | null {
  const directPath = path.join(outDir, `${contractName}.sol`, `${contractName}.json`);
  if (fs.existsSync(directPath)) {
    return directPath;
  }

  const entries = fs.readdirSync(outDir, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name === "build-info") continue;
    const candidate = path.join(outDir, entry.name, `${contractName}.json`);
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return null;
}

/**
 * Reads the ERC-1967 implementation address for a proxy.
 */
async function readProxyImplementation(
  provider: providers.JsonRpcProvider,
  proxyAddress: string
): Promise<string | null> {
  try {
    const slot = await provider.getStorageAt(proxyAddress, EIP1967_IMPL_SLOT);
    if (!slot || slot === "0x" + "0".repeat(64)) return null;
    const implAddress = "0x" + slot.slice(26).toLowerCase();
    if (implAddress === "0x" + "0".repeat(40)) return null;
    return implAddress;
  } catch {
    return null;
  }
}

/**
 * Resolves all contracts from the deployment state and on-chain data.
 *
 * For each known address:
 * 1. Maps it to an artifact via KNOWN_CONTRACT_NAMES
 * 2. If the address is an ERC-1967 proxy, ALSO registers the implementation
 *    address with the same artifact (so the implementation's PCs map correctly)
 */
export async function resolveContracts(
  deploymentState: Record<string, unknown>,
  outDir: string,
  rpcUrls: Map<string, string>
): Promise<ResolvedContract[]> {
  const resolved: ResolvedContract[] = [];
  const resolvedAddresses = new Set<string>();

  // Build list of known addresses from deployment state
  const l1Addresses = deploymentState.l1Addresses as Record<string, string> | undefined;
  const ctmAddresses = deploymentState.ctmAddresses as Record<string, string> | undefined;

  const knownAddresses: Array<{ address: string; fieldName: string }> = [];

  if (l1Addresses) {
    for (const [field, addr] of Object.entries(l1Addresses)) {
      if (typeof addr === "string" && addr.startsWith("0x")) {
        knownAddresses.push({ address: addr, fieldName: field });
      }
    }
  }
  if (ctmAddresses) {
    for (const [field, addr] of Object.entries(ctmAddresses)) {
      if (typeof addr === "string" && addr.startsWith("0x")) {
        knownAddresses.push({ address: addr, fieldName: field });
      }
    }
  }

  // Get L1 provider for proxy resolution
  const l1RpcUrl = rpcUrls.get("L1");
  const l1Provider = l1RpcUrl ? new providers.JsonRpcProvider(l1RpcUrl) : null;

  // Resolve each known address
  for (const { address, fieldName } of knownAddresses) {
    const addrLower = address.toLowerCase();
    if (resolvedAddresses.has(addrLower)) continue;

    const candidateNames = KNOWN_CONTRACT_NAMES[fieldName] || [];
    let artifactPath: string | null = null;

    for (const name of candidateNames) {
      artifactPath = findArtifactByName(outDir, name);
      if (artifactPath) break;
    }

    if (!artifactPath) {
      const capitalized = fieldName.charAt(0).toUpperCase() + fieldName.slice(1);
      artifactPath = findArtifactByName(outDir, capitalized);
    }

    if (!artifactPath) continue;

    const sourceMap = loadContractSourceMap(artifactPath);
    if (!sourceMap) continue;

    // Register the proxy address with this artifact (for depth-1 PC matching)
    resolved.push({ address: addrLower, name: sourceMap.name, artifactPath, sourceMap });
    resolvedAddresses.add(addrLower);

    // Check if this is an ERC-1967 proxy and also register the implementation
    if (l1Provider) {
      const implAddr = await readProxyImplementation(l1Provider, addrLower);
      if (implAddr && !resolvedAddresses.has(implAddr)) {
        // The implementation uses the same source map as the artifact.
        // PCs from DELEGATECALL execution match the implementation's bytecode,
        // which shares the same instruction layout as the artifact.
        resolved.push({ address: implAddr, name: sourceMap.name + " (impl)", artifactPath, sourceMap });
        resolvedAddresses.add(implAddr);
        console.log(`    🔗 ${fieldName}: proxy ${addrLower.slice(0, 10)}... -> impl ${implAddr.slice(0, 10)}... (${sourceMap.name})`);
      }
    }
  }

  console.log(`  📦 Resolved ${resolved.length} contracts from deployment state`);
  return resolved;
}

/**
 * Attempts to resolve a single address by fetching its bytecode and matching.
 */
export async function resolveByBytecode(
  address: string,
  provider: providers.JsonRpcProvider,
  outDir: string,
  bytecodeIndex?: Map<string, { artifactPath: string; fullBytecode: string }>
): Promise<ResolvedContract | null> {
  const index = bytecodeIndex || buildBytecodeIndex(outDir);

  try {
    const code = await provider.getCode(address);
    if (!code || code === "0x") return null;

    const artifactPath = matchBytecode(code, index);
    if (!artifactPath) return null;

    const sourceMap = loadContractSourceMap(artifactPath);
    if (!sourceMap) return null;

    return {
      address: address.toLowerCase(),
      name: sourceMap.name,
      artifactPath,
      sourceMap,
    };
  } catch {
    return null;
  }
}
