import { Command } from "commander";
import { Wallet } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { Deployer } from "../../l1-contracts/src.ts/deploy";
import { startWethBridgeInitOnChain } from "../../l1-contracts/src.ts/weth-initialize";
import { GAS_MULTIPLIER, deployedAddressesFromEnv, web3Provider } from "../../l1-contracts/scripts/utils";

import * as fs from "fs";
import * as path from "path";

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

async function main() {
  const program = new Command();

  program.version("0.1.0").name("initialize-weth-bridges-chain");

  program
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .action(async (cmd) => {
      const chainId: string = cmd.chainId ? cmd.chainId : process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID;
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/0"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
      console.log(`Using deployer nonce: ${nonce}`);

      const deployer = new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        verbose: true,
      });
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
