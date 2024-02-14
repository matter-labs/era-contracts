import { Command } from "commander";
import { ethers, Wallet } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { computeL2Create2Address, create2DeployFromL1, ethTestConfig, provider, priorityTxMaxGasLimit } from "./utils";

import { GAS_MULTIPLIER } from "../../l1-contracts/scripts/utils";
import * as hre from "hardhat";

async function main() {
  const program = new Command();

  program.version("0.1.0").name("initialize-erc20-bridge-chain");

  program
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--erc20-bridge <erc20-bridge>")
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
      console.log(`Using nonce: ${nonce}`);

      const l2SharedBridgeBytecode = hre.artifacts.readArtifactSync("L2SharedBridge").bytecode;
      const create2Salt = ethers.constants.HashZero;
      /// contracts that need to be deployed:
      /// - L2SharedBridge Implementation
      const forceDeployUpgraderAddress = computeL2Create2Address(
        deployWallet,
        l2SharedBridgeBytecode,
        "0x",
        create2Salt
      );

      // TODO: request from API how many L2 gas needs for the transaction.
      await create2DeployFromL1(
        chainId,
        deployWallet,
        l2SharedBridgeBytecode,
        "0x",
        create2Salt,
        priorityTxMaxGasLimit
      );

      /// L2SharedBridge Proxy

      /// L2WrappedBaseToken Implementation

      /// L2WrappedBaseToken Proxy

      /// L2StandardToken Implementation

      /// L2UpgradableBeacon

      /// L2StandardToken Proxy bytecode. We need this bytecode to be accessible on the L2

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
