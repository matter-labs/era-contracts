/**
 * Small utilities shared by the upgrade test runners. Extracted from the (deleted)
 * v31-upgrade-test-runner when the legacy v31 -> v32 harness was removed — the registry-driven
 * runner is their remaining consumer.
 */

import { ethers } from "ethers";
import type { ChainRole } from "../core/types";

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
