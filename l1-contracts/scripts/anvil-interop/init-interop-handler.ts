#!/usr/bin/env node

import { JsonRpcProvider, Contract, Wallet } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { getDefaultAccountPrivateKey } from "./src/utils";

/**
 * Initialize L2InteropHandler on all L2 chains
 */
async function main() {
  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l2) {
    throw new Error("No L2 chains found. Run 'yarn step1' first.");
  }

  console.log("\n=== Initializing L2InteropHandler ===\n");

  const L2_INTEROP_HANDLER_ADDR = "0x000000000000000000000000000000000001000e";
  const L2_COMPLEX_UPGRADER_ADDR = "0x000000000000000000000000000000000000800f";
  const privateKey = getDefaultAccountPrivateKey();

  const interopHandlerAbi = [
    "function initL2(uint256 _l1ChainId) public",
    "function L1_CHAIN_ID() external view returns (uint256)"
  ];

  for (const l2Chain of state.chains.l2) {
    console.log(`Chain ${l2Chain.chainId}:`);

    const provider = new JsonRpcProvider(l2Chain.rpcUrl);
    const wallet = new Wallet(privateKey, provider);

    const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, interopHandlerAbi, provider);

    // Check if already initialized
    let isInitialized = false;
    try {
      const l1ChainId = await interopHandler.L1_CHAIN_ID();
      if (l1ChainId === 1n) {
        console.log(`   ✅ L2InteropHandler already initialized\n`);
        continue;
      }
    } catch {}

    if (!isInitialized) {
      console.log(`   Initializing L2InteropHandler...`);

      // Impersonate L2_COMPLEX_UPGRADER to call initL2
      await provider.send("anvil_impersonateAccount", [L2_COMPLEX_UPGRADER_ADDR]);
      await provider.send("anvil_setBalance", [L2_COMPLEX_UPGRADER_ADDR, "0x56BC75E2D63100000"]);

      const signer = await provider.getSigner(L2_COMPLEX_UPGRADER_ADDR);
      const interopHandlerWithSigner = interopHandler.connect(signer);

      const tx = await interopHandlerWithSigner.getFunction("initL2")(1); // L1 chain ID = 1
      await tx.wait();

      await provider.send("anvil_stopImpersonatingAccount", [L2_COMPLEX_UPGRADER_ADDR]);

      console.log(`   ✅ L2InteropHandler initialized\n`);
    }
  }

  console.log("✅ L2InteropHandler initialized on all chains\n");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
