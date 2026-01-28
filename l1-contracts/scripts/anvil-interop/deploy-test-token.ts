#!/usr/bin/env node

import { JsonRpcProvider, Wallet, ContractFactory, Contract } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { getDefaultAccountPrivateKey } from "./src/utils";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploy TestToken ERC20 to all L2 chains for testing token transfers
 */
async function main() {
  console.log("\n=== Deploying TestToken to L2 Chains ===\n");

  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l2) {
    throw new Error("L2 chains not found");
  }

  const privateKey = getDefaultAccountPrivateKey();

  // Load TestToken artifact
  const artifactPath = path.join(__dirname, "../../out/TestToken.sol/TestToken.json");

  if (!fs.existsSync(artifactPath)) {
    throw new Error(`TestToken artifact not found at ${artifactPath}. Run 'forge build' first.`);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  const abi = artifact.abi;
  const bytecode = artifact.bytecode.object;

  console.log(`📦 TestToken bytecode length: ${bytecode.length} bytes\n`);

  const tokenAddresses: { [chainId: number]: string } = {};

  for (const chain of state.chains.l2) {
    console.log(`🚀 Deploying TestToken on chain ${chain.chainId}...`);
    const provider = new JsonRpcProvider(chain.rpcUrl);
    const wallet = new Wallet(privateKey, provider);

    try {
      // Deploy TestToken contract
      const factory = new ContractFactory(abi, bytecode, wallet);
      const token = await factory.deploy();
      await token.waitForDeployment();

      const tokenAddress = await token.getAddress();
      tokenAddresses[chain.chainId] = tokenAddress;

      console.log(`   ✅ TestToken deployed at ${tokenAddress}`);

      // Mint some tokens to the deployer using the ABI
      const mintInterface = new Contract(tokenAddress, ["function mint(address,uint256)"], wallet);
      const mintTx = await mintInterface.mint(wallet.address, BigInt(1000) * BigInt(10) ** BigInt(18));
      await mintTx.wait();

      console.log(`   ✅ Minted 1000 TEST tokens to ${wallet.address}\n`);

    } catch (error: any) {
      console.error(`   ❌ Failed to deploy on chain ${chain.chainId}: ${error.message}\n`);
    }
  }

  // Save token addresses to state by updating chains.json
  state.testTokens = tokenAddresses;
  fs.writeFileSync(
    path.join(__dirname, "outputs/state/chains.json"),
    JSON.stringify(state, null, 2)
  );

  console.log("=== ✅ TestToken Deployed to All Chains ===\n");
  console.log("Token Addresses:");
  for (const [chainId, address] of Object.entries(tokenAddresses)) {
    console.log(`  Chain ${chainId}: ${address}`);
  }
  console.log();
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
