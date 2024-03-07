// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";
import { Command } from "commander";
import { ethers, Wallet } from "ethers";
import { Deployer } from "../src.ts/deploy";

import { web3Provider } from "./utils";

import { ethTestConfig } from "../src.ts/utils";

async function main() {
  const program = new Command();

  program.version("0.1.0").name("deploy").description("deploy testkit contracts");

  program
    .requiredOption("--genesis-root <genesis-root>")
    .requiredOption("--genesis-rollup-leaf-index <genesis-rollup-leaf-index>")
    .action(async (cmd) => {
      process.env.CONTRACTS_GENESIS_ROOT = cmd.genesisRoot;
      process.env.CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX = cmd.genesisRollupLeafIndex;

      if (process.env.CHAIN_ETH_NETWORK !== "test") {
        console.error("This deploy script is only for localhost-test network");
        process.exit(1);
      }

      const provider = web3Provider();
      provider.pollingInterval = 10;

      const deployWallet = ethers.Wallet.fromMnemonic(ethTestConfig.test_mnemonic, "m/44'/60'/0'/0/0").connect(
        provider
      );

      const deployer = new Deployer({ deployWallet, verbose: true });
      await deployer.deployAll();

      const zkSyncContract = deployer.bridgehubContract(deployWallet);
      await (await zkSyncContract.setValidator(deployWallet.address, true)).wait();

      const tokenFactory = await hardhat.ethers.getContractFactory("TestnetERC20Token", deployWallet);
      const erc20 = await tokenFactory.deploy("Matter Labs Trial Token", "MLTT", 18, { gasLimit: 5000000 });

      console.log(`CONTRACTS_TEST_ERC20=${erc20.address}`);

      const failOnReceiveFactory = await hardhat.ethers.getContractFactory("FailOnReceive", deployWallet);
      const failOnReceive = await failOnReceiveFactory.deploy({
        gasLimit: 5000000,
      });
      console.log(`CONTRACTS_FAIL_ON_RECEIVE=${failOnReceive.address}`);

      for (let i = 0; i < 10; ++i) {
        const testWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic, "m/44'/60'/0'/0/" + i).connect(provider);
        await (await erc20.mint(testWallet.address, "0x4B3B4CA85A86C47A098A224000000000")).wait();
      }
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
