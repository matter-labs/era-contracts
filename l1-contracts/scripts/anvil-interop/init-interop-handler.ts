#!/usr/bin/env node

import { providers, Contract, Wallet } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { getDefaultAccountPrivateKey, loadAbiFromOut } from "./src/utils";
import { L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_HANDLER_ADDR } from "./src/const";

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

  const privateKey = getDefaultAccountPrivateKey();

  const interopHandlerAbi = loadAbiFromOut("InteropHandler.sol/InteropHandler.json");

  for (const l2Chain of state.chains.l2) {
    console.log(`Chain ${l2Chain.chainId}:`);

    const provider = new providers.JsonRpcProvider(l2Chain.rpcUrl);
    const wallet = new Wallet(privateKey, provider);

    const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, interopHandlerAbi, provider);

    // Check if already initialized
    const isInitialized = false;
    try {
      const l1ChainId = await interopHandler.L1_CHAIN_ID();
      if (l1ChainId?.toString?.() === "1") {
        console.log("   ✅ L2InteropHandler already initialized\n");
        continue;
      }
    } catch {}

    if (!isInitialized) {
      console.log("   Initializing L2InteropHandler...");

      // Impersonate L2_COMPLEX_UPGRADER to call initL2
      await provider.send("anvil_impersonateAccount", [L2_COMPLEX_UPGRADER_ADDR]);
      await provider.send("anvil_setBalance", [L2_COMPLEX_UPGRADER_ADDR, "0x56BC75E2D63100000"]);

      const signer = await provider.getSigner(L2_COMPLEX_UPGRADER_ADDR);
      const interopHandlerWithSigner = interopHandler.connect(signer);

      const tx = await interopHandlerWithSigner.initL2(1); // L1 chain ID = 1
      await tx.wait();

      await provider.send("anvil_stopImpersonatingAccount", [L2_COMPLEX_UPGRADER_ADDR]);

      console.log("   ✅ L2InteropHandler initialized\n");
    }
  }

  console.log("✅ L2InteropHandler initialized on all chains\n");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
