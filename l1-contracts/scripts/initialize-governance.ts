import { Command } from "commander";
import { ethers, formatUnits, parseUnits, Wallet } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { web3Provider } from "./utils";

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
        : Wallet.fromPhrase(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
          ).derivePath("m/44'/60'/0'/0/1").connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.getAddress()}`);

      const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, "gwei") : (await provider.getFeeData()).gasPrice;
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const ownerAddress = cmd.ownerAddress ? cmd.ownerAddress : deployWallet.getAddress();

      const deployer = new Deployer({
        deployWallet,
        ownerAddress,
        verbose: true,
      });

      const governance = deployer.governanceContract(deployWallet);
      const zkSync = deployer.zkSyncContract(deployWallet);

      const erc20Bridge = deployer.transparentUpgradableProxyContract(
        deployer.addresses.Bridges.ERC20BridgeProxy,
        deployWallet
      );
      const wethBridge = deployer.transparentUpgradableProxyContract(
        deployer.addresses.Bridges.WethBridgeProxy,
        deployWallet
      );

      await (await erc20Bridge.changeAdmin(await governance.getAddress())).wait();
      await (await wethBridge.changeAdmin(await governance.getAddress())).wait();

      await (await zkSync.setPendingGovernor(await governance.getAddress())).wait();

      const call = {
        target: await zkSync.getAddress(),
        value: 0,
        data: zkSync.interface.encodeFunctionData("acceptGovernor"),
      };

      const operation = {
        calls: [call],
        predecessor: ethers.ZeroHash,
        salt: ethers.ZeroHash,
      };

      await (await governance.scheduleTransparent(operation, 0)).wait();
      await (await governance.execute(operation)).wait();
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
