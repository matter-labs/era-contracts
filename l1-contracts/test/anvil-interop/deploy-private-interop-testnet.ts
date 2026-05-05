#!/usr/bin/env node

/**
 * Deploy private interop stack to live testnet chains.
 * Uses the shared deployer with gas overrides and pre-v31 fallbacks.
 *
 * Usage: DEPLOYER_PK=0x... npx ts-node deploy-private-interop-testnet.ts
 */

import { providers } from "ethers";
import { deployPrivateInteropStack, registerRemoteRouters } from "./src/helpers/private-interop-deployer";
import type { PrivateInteropAddresses } from "./src/helpers/private-interop-deployer";

const DEPLOYER_PK = process.env.DEPLOYER_PK;
if (!DEPLOYER_PK) {
  console.error("Set DEPLOYER_PK environment variable");
  process.exit(1);
}

const L1_CHAIN_ID = 11155111; // Sepolia

const CHAINS = [
  { name: "zksync_os_testnet", chainId: 8022833, rpcUrl: "https://zksync-os-testnet-alpha.zksync.dev" },
  { name: "creator_testnet", chainId: 278701, rpcUrl: "https://rpc.testnet.oncreator.com" },
  { name: "union_testnet", chainId: 2905, rpcUrl: "https://zksync-os-testnet-union.zksync.dev" },
];

async function main() {
  // Filter chains by name/chainId if specified: CHAIN=creator or CHAIN=278701
  const filterArg = process.env.CHAIN;
  const targetChains = filterArg
    ? CHAINS.filter((c) => c.name === filterArg || c.chainId.toString() === filterArg)
    : CHAINS;
  if (targetChains.length === 0) {
    console.error(`No chain matching "${filterArg}". Available: ${CHAINS.map((c) => c.name).join(", ")}`);
    process.exit(1);
  }

  const allChainIds = CHAINS.map((c) => c.chainId);
  const results: Record<number, PrivateInteropAddresses> = {};

  for (const chain of targetChains) {
    console.log(`\n=== ${chain.name} (chain ${chain.chainId}) ===`);
    try {
      const provider = new providers.JsonRpcProvider(chain.rpcUrl);
      const gasPrice = await provider.getGasPrice();

      results[chain.chainId] = await deployPrivateInteropStack(
        chain.rpcUrl,
        chain.chainId,
        L1_CHAIN_ID,
        (line) => console.log(`  ${line}`),
        {
          deployerKey: DEPLOYER_PK,
          skipFunding: true,
          deployGasOverrides: { gasPrice: gasPrice.mul(2), gasLimit: 30_000_000, type: 0 },
          initGasOverrides: { gasPrice: gasPrice.mul(2), gasLimit: 10_000_000, type: 0 },
          destinationChainIds: allChainIds,
        }
      );
    } catch (error) {
      console.error(`  FAILED: ${(error as Error).message}`);
    }
  }

  // Cross-register remote routers
  console.log("\n=== Registering remote routers ===");
  const chainsWithResults = targetChains.filter((c) => results[c.chainId]);
  if (chainsWithResults.length > 1) {
    const gasPrice = await new providers.JsonRpcProvider(chainsWithResults[0].rpcUrl).getGasPrice();
    await registerRemoteRouters(chainsWithResults, results, DEPLOYER_PK!, console.log, {
      gasPrice: gasPrice.mul(2),
      gasLimit: 1_000_000,
      type: 0,
    });
  }

  console.log("\n\n=== ALL DEPLOYMENTS ===");
  console.log(JSON.stringify(results, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
