// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { Wallet, ethers } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { web3Provider, GAS_MULTIPLIER, web3Url } from "./utils";
import { deployedAddressesFromEnv } from "../src.ts/deploy-utils";
import { initialBridgehubDeployment } from "../src.ts/deploy-process";
import { ethTestConfig } from "../src.ts/utils";
import { Wallet as ZkWallet, Provider as ZkProvider } from "zksync-ethers";

const provider = web3Provider();

async function main() {
  const program = new Command();

  program.version("0.1.0").name("deploy").description("deploy L1 contracts");

  program
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--owner-address <owner-address>")
    .option("--create2-salt <create2-salt>")
    .option("--diamond-upgrade-init <version>")
    .option("--only-verifier")
    .action(async (cmd) => {
      let deployWallet: ethers.Wallet | ZkWallet;

      if (process.env.CONTRACTS_BASE_NETWORK_ZKSYNC === "true") {
        const provider = new ZkProvider(web3Url());
        deployWallet = cmd.privateKey
          ? new ZkWallet(cmd.privateKey, provider)
          : ZkWallet.fromMnemonic(
              process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
              "m/44'/60'/0'/0/1"
            ).connect(provider);
      } else {
        deployWallet = cmd.privateKey
          ? new Wallet(cmd.privateKey, provider)
          : Wallet.fromMnemonic(
              process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
              "m/44'/60'/0'/0/1"
            ).connect(provider);
      }

      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const ownerAddress = cmd.ownerAddress ? cmd.ownerAddress : deployWallet.address;
      console.log(`Using owner address: ${ownerAddress}`);

      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      const create2Salt = cmd.create2Salt ? cmd.create2Salt : ethers.utils.hexlify(ethers.utils.randomBytes(32));

      const deployer = new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress,
        verbose: true,
      });

      if (deployer.isZkMode()) {
        console.log("Deploying on a zkSync network!");
      }

      await initialBridgehubDeployment(deployer, [], gasPrice, cmd.onlyVerifier, create2Salt, nonce);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
