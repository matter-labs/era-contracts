import { ethers, providers } from "ethers";
import { getAbi } from "../core/contracts";
import type { ForkConfig } from "../core/fork-config";

export interface ForkDiscoveredChain {
  chainId: number;
  diamondProxy: string;
  chainAdmin: string;
  l2RpcUrl: string;
}

/**
 * Query the forked L1 Bridgehub for all registered chains, pick the test subset,
 * and resolve per-chain diamond proxy / admin / L2 RPC URL.
 *
 * Selection rule: if cfg.chainIdFilter is non-empty, use exactly those chains
 * (in order). Otherwise, take the first 2 chains returned by getAllZKChainChainIDs().
 */
export async function discoverForkChains(
  l1Provider: providers.JsonRpcProvider,
  cfg: ForkConfig
): Promise<ForkDiscoveredChain[]> {
  const bridgehub = new ethers.Contract(cfg.bridgehubAddress, getAbi("L1Bridgehub"), l1Provider);
  const rawIds: ethers.BigNumber[] = await bridgehub.getAllZKChainChainIDs();
  const allChainIds = rawIds.map((n) => n.toNumber());
  if (allChainIds.length === 0) {
    throw new Error(`Bridgehub ${cfg.bridgehubAddress} reports no registered chains on the forked L1`);
  }

  let selected: number[];
  if (cfg.chainIdFilter.length > 0) {
    for (const id of cfg.chainIdFilter) {
      if (!allChainIds.includes(id)) {
        throw new Error(`FORK_CHAIN_IDS includes chain ${id}, but it is not registered on the forked Bridgehub`);
      }
    }
    selected = cfg.chainIdFilter;
  } else {
    selected = allChainIds.slice(0, 2);
  }

  if (selected.length === 0) {
    throw new Error("No chains selected for fork-mode upgrade test");
  }

  const adminAbi = getAbi("GettersFacet");
  const result: ForkDiscoveredChain[] = [];
  for (const chainId of selected) {
    const diamondProxy: string = await bridgehub.getZKChain(chainId);
    if (!diamondProxy || diamondProxy === ethers.constants.AddressZero) {
      throw new Error(`Chain ${chainId}: diamond proxy not found on the forked Bridgehub`);
    }
    const getters = new ethers.Contract(diamondProxy, adminAbi, l1Provider);
    const chainAdmin: string = await getters.getAdmin();
    const l2RpcUrl = cfg.l2RpcByChainId.get(chainId);
    if (!l2RpcUrl) {
      throw new Error(
        `Chain ${chainId}: no L2 RPC URL configured. Set L2_FORK_URL_${chainId} or add it to config/fork-l2-rpcs.json`
      );
    }
    result.push({ chainId, diamondProxy, chainAdmin, l2RpcUrl });
  }
  return result;
}
