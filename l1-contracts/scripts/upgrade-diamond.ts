// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { Wallet, ethers } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { web3Provider, GAS_MULTIPLIER } from "./utils";
import { deployedAddressesFromEnv } from "../src.ts/deploy-utils";
import { IZkSyncHyperchainFactory } from "../typechain/IZkSyncHyperchainFactory";
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
      const deployWallet = new Wallet("DEPLOYER_WALLET", provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

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

      const contractAddress1 = await deployer.deployViaCreate2("Verifier", [], create2Salt, {
        gasPrice,
        nonce,
        gasLimit: 10_000_000,
      });
      nonce++;
      console.log(`VERIFIER ADDR: ${contractAddress1}`);

      const contractAddress2 = await deployer.deployViaCreate2("UpgradeVerifier", [], create2Salt, { gasPrice, nonce });
      nonce++;
      console.log(`UPGRADE VERIFIER ADDR: ${contractAddress2}`);

      // STEP 2: uncomment this code, insert the correct address and calldata, and run
      // const diamond = StateTransitionManagerFactory.connect(deployer.addresses.StateTransition.StateTransitionProxy, deployer.deployWallet);
      // let tx = await diamond.executeUpgrade(
      //     282, {
      //         facetCuts: [],
      //         initAddress: "INIT_ADDRESS",
      //         initCalldata: "INIT_CALLDATA" // call to the()
      //     }, {gasPrice, nonce: nonce});
      // const receipt = await tx.wait();
      // console.log(receipt);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
