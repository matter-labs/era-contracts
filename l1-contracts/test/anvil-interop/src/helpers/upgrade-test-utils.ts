/**
 * Small utilities shared by the upgrade test runners. Extracted from the (deleted)
 * v31-upgrade-test-runner when the legacy v31 -> v32 harness was removed — the registry-driven
 * runner is their remaining consumer.
 */

import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { EIP1967_ADMIN_SLOT, EIP1967_IMPL_SLOT, SEMVER_MAJOR_OFFSET, SEMVER_MINOR_OFFSET } from "../core/const";
import type { ChainRole } from "../core/types";

// The genesis config the default upgrade scripts read their target version from.
const ZKSYNC_OS_GENESIS_PATH = path.resolve(__dirname, "../../../../../configs/genesis/zksync-os/latest.json");

export type SemVer = { major: number; minor: number; patch: number };

/**
 * The protocol version in the ZKsync OS genesis config: the version `DefaultCoreUpgrade` / `DefaultCTMUpgrade`
 * upgrade to, so the target of protocol-ops' default upgrade.
 */
export function readGenesisSemVer(): SemVer {
  const genesis = JSON.parse(fs.readFileSync(ZKSYNC_OS_GENESIS_PATH, "utf-8")) as {
    protocol_semantic_version: SemVer;
  };
  return genesis.protocol_semantic_version;
}

/** `version` packed like `SemVer.packSemVer`, as a hex string. */
export function packProtocolVersion(version: SemVer): string {
  return ethers.BigNumber.from(version.major)
    .shl(SEMVER_MAJOR_OFFSET)
    .or(ethers.BigNumber.from(version.minor).shl(SEMVER_MINOR_OFFSET))
    .or(version.patch)
    .toHexString();
}

/**
 * Test-only compatibility bridge: the pre-generated chain states still carry the genesis-upgrade
 * tx hash from chain creation, which a real chain's server clears once it processes the batch and
 * which otherwise blocks a new upgrade with `PreviousUpgradeNotFinalized`.
 */
export async function clearGenesisUpgradeTxHash(
  provider: ethers.providers.JsonRpcProvider,
  chains: Array<{ chainId: number; diamondProxy: string }>
): Promise<void> {
  for (const chain of chains) {
    await provider.send("anvil_setStorageAt", [chain.diamondProxy, "0x22", ethers.constants.HashZero]);
  }
}

/** A transparent proxy's admin, read from its EIP-1967 slot: the proxy answers `admin()` only to it. */
export async function readProxyAdmin(provider: ethers.providers.Provider, proxy: string): Promise<string> {
  return readAddressSlot(provider, proxy, EIP1967_ADMIN_SLOT);
}

/** A transparent proxy's implementation, read from its EIP-1967 slot. */
export async function readProxyImplementation(provider: ethers.providers.Provider, proxy: string): Promise<string> {
  return readAddressSlot(provider, proxy, EIP1967_IMPL_SLOT);
}

async function readAddressSlot(provider: ethers.providers.Provider, account: string, slot: string): Promise<string> {
  return ethers.utils.getAddress(ethers.utils.hexDataSlice(await provider.getStorageAt(account, slot), 12));
}

export function selectUpgradeChains(
  chainAddresses: Array<{ chainId: number; diamondProxy: string }>,
  chainConfigs: Array<{ chainId: number; role: ChainRole }>,
  targetRoles: ChainRole[]
): Array<{ chainId: number; diamondProxy: string }> {
  const roles = new Map(chainConfigs.map((c) => [c.chainId, c.role]));
  return chainAddresses.filter((chain) => {
    const role = roles.get(chain.chainId);
    if (!role) throw new Error(`Missing chain role for chain ${chain.chainId}`);
    return targetRoles.includes(role);
  });
}

/**
 * Trace a failed transaction via receipt + eth_call replay and return a human-readable summary.
 */
export async function traceFailedTx(provider: ethers.providers.JsonRpcProvider, txHash: string): Promise<string> {
  try {
    const tx = await provider.getTransaction(txHash);
    const receipt = await provider.getTransactionReceipt(txHash);
    const selector = tx.data?.slice(0, 10) ?? "unknown";
    const lines = [
      `  tx: ${txHash}`,
      `  from: ${tx.from}`,
      `  to: ${tx.to}`,
      `  selector: ${selector}`,
      `  gasUsed: ${receipt?.gasUsed?.toString() ?? "?"}`,
      `  block: ${receipt?.blockNumber ?? "?"}`,
    ];

    // Try to get revert reason via eth_call replay
    try {
      await provider.call(
        { from: tx.from, to: tx.to!, data: tx.data, value: tx.value, gasLimit: tx.gasLimit },
        receipt?.blockNumber ? receipt.blockNumber - 1 : "latest"
      );
    } catch (callErr: unknown) {
      const reason =
        callErr instanceof Error
          ? ((callErr as { reason?: string }).reason ?? callErr.message.slice(0, 200))
          : String(callErr).slice(0, 200);
      lines.push(`  revert reason: ${reason}`);
    }

    lines.push(`  Debug: cast run ${txHash} --rpc-url ${provider.connection.url}`);
    return lines.join("\n");
  } catch {
    return `  tx: ${txHash}\n  (could not fetch trace details)`;
  }
}
