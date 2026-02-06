#!/usr/bin/env node

import * as fs from "fs";
import * as path from "path";
import { JsonRpcProvider } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";

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

  const L2_MESSAGE_VERIFICATION_ADDR = "0x0000000000000000000000000000000000010009";
  const contractsRoot = path.resolve(__dirname, "../../..");
  const contractPath = path.join(contractsRoot, "l1-contracts/out/MockL2MessageVerification.sol/MockL2MessageVerification.json");
  const artifact = JSON.parse(fs.readFileSync(contractPath, "utf-8"));
  const bytecode = artifact.deployedBytecode?.object || artifact.bytecode?.object;

  if (!bytecode || bytecode === "0x") {
    throw new Error("No bytecode found for MockL2MessageVerification");
  }

  for (const l2Chain of state.chains.l2) {
    console.log(`Chain ${l2Chain.chainId}:`);

    const provider = new JsonRpcProvider(l2Chain.rpcUrl);

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
