#!/usr/bin/env node

import type { BigNumber } from "ethers";
import { ethers, providers, Wallet, ContractFactory } from "ethers";
import { DeploymentRunner } from "../deployment-runner";
import { ANVIL_DEFAULT_PRIVATE_KEY, TEST_TOKEN_DECIMALS, TEST_TOKEN_MINT_AMOUNT_UNITS } from "../core/const";
import { getAbi, getCreationBytecode } from "../core/contracts";
import { getInteropSourcePrivateKey } from "../core/accounts";
import * as fs from "fs";
import * as path from "path";

export interface DeployL2NativeTokenParams {
  provider: providers.JsonRpcProvider;
  chainId: number;
  name: string;
  symbol: string;
  decimals?: number;
  mintAmount?: BigNumber;
  privateKey?: string;
}

export async function deployL2NativeToken(params: DeployL2NativeTokenParams): Promise<string> {
  const decimals = params.decimals ?? TEST_TOKEN_DECIMALS;
  const mintAmount = params.mintAmount ?? ethers.utils.parseUnits(TEST_TOKEN_MINT_AMOUNT_UNITS, decimals);
  const wallet = new Wallet(params.privateKey || getInteropSourcePrivateKey(), params.provider);
  const factory = new ContractFactory(getAbi("TestnetERC20Token"), getCreationBytecode("TestnetERC20Token"), wallet);
  const token = await factory.deploy(params.name, params.symbol, decimals);
  await token.deployed();

  const mintTx = await token.mint(wallet.address, mintAmount);
  await mintTx.wait();
  console.log(`   L2 native token deployed on chain ${params.chainId}: ${token.address}`);

  return token.address;
}

/**
 * Deploy TestToken ERC20 to all L2 chains for testing token transfers.
 * Deploys to all chains in parallel for speed.
 */
export async function deployTestTokens(): Promise<void> {
  console.log("\n=== Deploying TestToken to L2 Chains ===\n");

  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l2) {
    throw new Error("L2 chains not found");
  }

  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  // Load TestnetERC20Token artifact
  const artifactPath = path.join(__dirname, "../../../../out/TestnetERC20Token.sol/TestnetERC20Token.json");

  if (!fs.existsSync(artifactPath)) {
    throw new Error(`TestnetERC20Token artifact not found at ${artifactPath}. Run 'forge build' first.`);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  const abi = artifact.abi;
  const bytecode = artifact.bytecode.object;

  console.log(`📦 TestnetERC20Token bytecode length: ${bytecode.length} bytes\n`);

  const tokenAddresses: { [chainId: number]: string } = {};

  // Deploy to all chains in parallel
  await Promise.all(
    state.chains.l2.map(async (chain) => {
      console.log(`🚀 Deploying TestToken on chain ${chain.chainId}...`);
      const provider = new providers.JsonRpcProvider(chain.rpcUrl);
      const wallet = new Wallet(privateKey, provider);

      try {
        const factory = new ContractFactory(abi, bytecode, wallet);
        const token = await factory.deploy("Test Token", "TEST", TEST_TOKEN_DECIMALS);
        await token.deployed();

        const tokenAddress = token.address;
        tokenAddresses[chain.chainId] = tokenAddress;

        console.log(`   ✅ TestnetERC20Token deployed at ${tokenAddress} (chain ${chain.chainId})`);

        const mintTx = await token.mint(
          wallet.address,
          ethers.utils.parseUnits(TEST_TOKEN_MINT_AMOUNT_UNITS, TEST_TOKEN_DECIMALS)
        );
        await mintTx.wait();

        console.log(
          `   ✅ Minted ${TEST_TOKEN_MINT_AMOUNT_UNITS} TEST tokens to ${wallet.address} (chain ${chain.chainId})`
        );
      } catch (error: unknown) {
        console.error(`   ❌ Failed to deploy on chain ${chain.chainId}: ${(error as Error).message}\n`);
      }
    })
  );

  // Save token addresses to state by updating chains.json
  // Re-load state to avoid overwriting concurrent changes
  const freshState = runner.loadState();
  freshState.testTokens = tokenAddresses;
  runner.saveState(freshState);

  console.log("=== ✅ TestToken Deployed to All Chains ===\n");
  console.log("Token Addresses:");
  for (const [chainId, address] of Object.entries(tokenAddresses)) {
    console.log(`  Chain ${chainId}: ${address}`);
  }
  console.log();
}

// Allow running as standalone script
if (require.main === module) {
  deployTestTokens().catch((error) => {
    console.error("❌ Failed:", error);
    process.exit(1);
  });
}
