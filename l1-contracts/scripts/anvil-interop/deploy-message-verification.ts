#!/usr/bin/env node

import { providers } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { L2_MESSAGE_VERIFICATION_ADDR } from "./src/const";
import { loadBytecodeFromOut } from "./src/utils";

/**
 * Deploy MockL2MessageVerification on all L2 chains for Anvil testing
 * This mock always returns true for message inclusion proofs, bypassing L1 settlement
 */
async function main() {
  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l2) {
    throw new Error("No L2 chains found. Run 'yarn step1' first.");
  }

  console.log("\n=== Deploying MockL2MessageVerification (Anvil Testing) ===\n");

  const bytecode = loadBytecodeFromOut("MockL2MessageVerification.sol/MockL2MessageVerification.json");

  if (!bytecode || bytecode === "0x") {
    throw new Error("No bytecode found for MockL2MessageVerification");
  }

  for (const l2Chain of state.chains.l2) {
    console.log(`Chain ${l2Chain.chainId}:`);

    const provider = new providers.JsonRpcProvider(l2Chain.rpcUrl);

    // Always redeploy the mock (force replace)
    console.log(`   Deploying MockL2MessageVerification at ${L2_MESSAGE_VERIFICATION_ADDR}...`);
    await provider.send("anvil_setCode", [L2_MESSAGE_VERIFICATION_ADDR, bytecode]);
    console.log(`   ✅ MockL2MessageVerification deployed (bypasses proof verification)\n`);
  }

  console.log("✅ MockL2MessageVerification deployed on all chains\n");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
