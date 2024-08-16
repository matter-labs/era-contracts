import { Command } from "commander";

import * as hre from "hardhat";
import { L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS } from "../../l1-contracts/src.ts/utils";

export const L2_STANDARD_TOKEN_PROXY_BYTECODE = hre.artifacts.readArtifactSync("BeaconProxy").bytecode;

async function main() {
  const program = new Command();

  program.version("0.1.0").name("deploy-shared-bridge-on-l2-through-l1");

  program
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--local-legacy-bridge-testing")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--erc20-bridge <erc20-bridge>")
    .option("--skip-initialize-chain-governance <skip-initialize-chain-governance>")
    .action(async () => {
      console.log(`CONTRACTS_L2_NATIVE_TOKEN_VAULT_IMPL_ADDR=${L2_NATIVE_TOKEN_VAULT_ADDRESS}`);
      console.log(`CONTRACTS_L2_NATIVE_TOKEN_VAULT_PROXY_ADDR=${L2_NATIVE_TOKEN_VAULT_ADDRESS}`);
      console.log(`CONTRACTS_L2_SHARED_BRIDGE_IMPL_ADDR=${L2_ASSET_ROUTER_ADDRESS}`);
      console.log(`CONTRACTS_L2_SHARED_BRIDGE_ADDR=${L2_ASSET_ROUTER_ADDRESS}`);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
