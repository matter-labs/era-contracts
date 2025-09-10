import { Command } from "commander";
import type { BigNumberish } from "ethers";
import { ethers, Wallet } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { computeL2Create2Address, create2DeployFromL1, provider, priorityTxMaxGasLimit } from "./utils";

import { ethTestConfig } from "./deploy-utils";

import { Deployer } from "../../l1-contracts/src.ts/deploy";
import { GAS_MULTIPLIER } from "../../l1-contracts/scripts/utils";
import { AdminFacetFactory } from "../../l1-contracts/typechain";
import * as hre from "hardhat";

async function deployContractOnL2ThroughL1(
  deployer: Deployer,
  name: string,
  chainId: string,
  gasPrice: BigNumberish
): Promise<string> {
  const bytecode = hre.artifacts.readArtifactSync(name).bytecode;
  const address = computeL2Create2Address(
    deployer.deployWallet,
    bytecode,
    // Empty constructor data
    "0x",
    ethers.constants.HashZero
  );

  const tx = await create2DeployFromL1(
    chainId,
    deployer.deployWallet,
    bytecode,
    "0x",
    ethers.constants.HashZero,
    priorityTxMaxGasLimit,
    gasPrice
  );

  await tx.wait();

  return address;
}

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
    .option("--validium-mode")
    .action(async (cmd) => {
      const chainId: string = cmd.chainId ? cmd.chainId : process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID;
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const deployer = new Deployer({
        deployWallet,
        ownerAddress: deployWallet.address,
        verbose: true,
      });

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployer.deployWallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      let l2DaValidatorAddress;
      let l1DaValidatorAddress;
      if (cmd.validiumMode) {
        l2DaValidatorAddress = await deployContractOnL2ThroughL1(deployer, "ValidiumL2DAValidator", chainId, gasPrice);
        l1DaValidatorAddress = deployer.addresses.ValidiumL1DAValidator;
      } else {
        l2DaValidatorAddress = await deployContractOnL2ThroughL1(deployer, "RollupL2DAValidator", chainId, gasPrice);
        l1DaValidatorAddress = deployer.addresses.RollupL1DAValidator;
      }

      console.log(`CONTRACTS_L1_DA_VALIDATOR_ADDR=${l1DaValidatorAddress}`);
      console.log(`CONTRACTS_L2_DA_VALIDATOR_ADDR=${l2DaValidatorAddress}`);

      const adminFacetInterface = new AdminFacetFactory().interface;

      console.log("Setting the DA Validator pair on diamond proxy");
      console.log("Who is called: ", deployer.addresses.StateTransition.DiamondProxy);
      await deployer.executeChainAdminMulticall([
        {
          target: deployer.addresses.StateTransition.DiamondProxy,
          data: adminFacetInterface.encodeFunctionData("setDAValidatorPair", [
            l1DaValidatorAddress,
            l2DaValidatorAddress,
          ]),
          value: 0,
        },
      ]);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
