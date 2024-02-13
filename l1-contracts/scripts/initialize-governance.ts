import { Command } from "commander";
import { Wallet } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { Deployer } from "../src.ts/deploy";
import { GAS_MULTIPLIER, web3Provider } from "./utils";
import { deployedAddressesFromEnv } from "../src.ts/deploy-utils";

import * as fs from "fs";
import * as path from "path";

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

async function main() {
  const program = new Command();

  program.version("0.1.0").name("initialize-governance");

  program
    .option("--private-key <private-key>")
    .option("--owner-address <owner-address>")
    .option("--gas-price <gas-price>")
    .action(async (cmd) => {
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const ownerAddress = cmd.ownerAddress ? cmd.ownerAddress : deployWallet.address;

      const deployer = new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress,
        verbose: true,
      });

      // const governance =
      deployer.governanceContract(deployWallet);

      // const erc20Bridge =
      deployer.transparentUpgradableProxyContract(deployer.addresses.Bridges.ERC20BridgeProxy, deployWallet);
      // const wethBridge = deployer.transparentUpgradableProxyContract(
      //   deployer.addresses.Bridges.WethBridgeProxy,
      //   deployWallet
      // );

      // await (await erc20Bridge.changeAdmin(governance.address)).wait();
      // await (await wethBridge.changeAdmin(governance.address)).wait();
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
