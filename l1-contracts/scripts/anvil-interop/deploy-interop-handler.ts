#!/usr/bin/env node

import * as fs from "fs";
import * as path from "path";
import { JsonRpcProvider } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";

/**
 * Deploy L2InteropHandler on all L2 chains
 */
async function main() {
  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l2) {
    throw new Error("No L2 chains found. Run 'yarn step1' first.");
  }

  console.log("\n=== Deploying L2InteropHandler ===\n");

  const L2_INTEROP_HANDLER_ADDR = "0x000000000000000000000000000000000001000e";
  const contractsRoot = path.resolve(__dirname, "../../..");
  const contractPath = path.join(contractsRoot, "l1-contracts/out/InteropHandler.sol/InteropHandler.json");
  const artifact = JSON.parse(fs.readFileSync(contractPath, "utf-8"));
  const bytecode = artifact.deployedBytecode?.object || artifact.bytecode?.object;

  if (!bytecode || bytecode === "0x") {
    throw new Error("No bytecode found for InteropHandler");
  }

  for (const l2Chain of state.chains.l2) {
    console.log(`Chain ${l2Chain.chainId}:`);

    const provider = new JsonRpcProvider(l2Chain.rpcUrl);

    // Check if already deployed
    const existingCode = await provider.getCode(L2_INTEROP_HANDLER_ADDR);
    if (existingCode !== "0x" && existingCode !== "0x0") {
      console.log(`   ✅ L2InteropHandler already deployed\n`);
      continue;
    }

    // Deploy using anvil_setCode
    console.log(`   Deploying L2InteropHandler at ${L2_INTEROP_HANDLER_ADDR}...`);
    await provider.send("anvil_setCode", [L2_INTEROP_HANDLER_ADDR, bytecode]);
    console.log(`   ✅ L2InteropHandler deployed\n`);
  }

  console.log("✅ L2InteropHandler deployed on all chains\n");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
