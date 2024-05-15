// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { Wallet } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { web3Provider, GAS_MULTIPLIER } from "./utils";
import { deployedAddressesFromEnv } from "../src.ts/deploy-utils";
import { StateTransitionManagerFactory } from "../typechain";

const provider = web3Provider();

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-diamond").description("upgrade diamond contracts");

  program
    .option("--private-key <private-key>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--owner-address <owner-address>")
    .option("--create2-salt <create2-salt>")
    .action(async (cmd) => {
      const deployWallet = new Wallet("", provider); //TODO: put deployer PK here
      const govWallet = new Wallet("", provider); // TODO: put governor PK here
      console.log(`Using deployer wallet: ${deployWallet.address}`);
      console.log(`Using governor wallet: ${govWallet.address}`);

      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      let nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      const create2Salt = cmd.create2Salt
        ? cmd.create2Salt
        : "0x0000000000000000000000000000000000000000000000000000000000000001";
      console.log(`Create2 salt: ${create2Salt}`);

      const deployer = new Deployer({
        deployWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress: deployWallet.address,
        verbose: true,
      });

      const govDeployer = new Deployer({
        deployWallet: govWallet,
        addresses: deployedAddressesFromEnv(),
        ownerAddress: deployWallet.address,
        verbose: true,
      });
      govDeployer.addresses.Governance = ""; // TODO: put governance address here

      // TODO: replace UpgradeBootloaderHash to the name of your upgrade
      const upgradeAddress = await deployer.deployViaCreate2("UpgradeBootloaderHash", [], create2Salt, { gasPrice, nonce });
      nonce++;
      console.log(`UPGRADE ADDR: ${upgradeAddress}`);

      const stm = StateTransitionManagerFactory.connect(
        govDeployer.addresses.StateTransition.StateTransitionProxy,
        govDeployer.deployWallet
      );

      await govDeployer.executeUpgrade(
          govDeployer.addresses.StateTransition.StateTransitionProxy,
        0,
          stm.interface.encodeFunctionData("executeUpgrade", [
              9, // TODO: set your chain ID here
              {
                  facetCuts: [],
                  initAddress: upgradeAddress,
                  initCalldata: "", // TODO: set your init calldata here(use abi-encode with your upgrade signature and arguments)
              }
          ])
      );
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
