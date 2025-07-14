// hardhat import should be the first import in the file
import * as hre from "hardhat";

import { Command } from "commander";
import { ethers, Wallet } from "ethers";
import { computeL2Create2Address, create2DeployFromL1, priorityTxMaxGasLimit, provider } from "./utils";
import { ethTestConfig } from "./deploy-utils";

// Script to deploy the force deploy upgrader contract and output its address.
// Note, that this script expects that the L2 contracts have been compiled PRIOR
// to running this script.
async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("deploy-force-deploy-upgrader-through-l1")
    .option("--chain-id <chain-id>")
    .description("Deploys the force deploy upgrader contract to L2");

  program.option("--private-key <private-key>").action(async (cmd) => {
    const chainId: string = cmd.chainId ? cmd.chainId : process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID;
    const deployWallet = cmd.privateKey
      ? new Wallet(cmd.privateKey, provider)
      : Wallet.fromMnemonic(
          process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
          "m/44'/60'/0'/0/1"
        ).connect(provider);
    console.log(`Using deployer wallet: ${deployWallet.address}`);

    const forceDeployUpgraderBytecode = hre.artifacts.readArtifactSync("ForceDeployUpgrader").bytecode;
    const create2Salt = ethers.constants.HashZero;
    const forceDeployUpgraderAddress = computeL2Create2Address(
      deployWallet,
      forceDeployUpgraderBytecode,
      "0x",
      create2Salt
    );

    // TODO: request from API how many L2 gas needs for the transaction.
    await create2DeployFromL1(
      chainId,
      deployWallet,
      forceDeployUpgraderBytecode,
      "0x",
      create2Salt,
      priorityTxMaxGasLimit
    );

    console.log(`CONTRACTS_L2_DEFAULT_UPGRADE_ADDR=${forceDeployUpgraderAddress}`);
  });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
