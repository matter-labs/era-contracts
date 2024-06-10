/// This script is needed to migrate the ownership for key contracts to the governance multisig

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { Wallet, ethers } from "ethers";
import { formatUnits, parseUnits, Interface } from "ethers/lib/utils";
import { web3Provider, GAS_MULTIPLIER } from "./utils";
import { ethTestConfig } from "../src.ts/utils";

const ownable2StepInterface = new Interface(hardhat.artifacts.readArtifactSync("ValidatorTimelock").abi);
const governanceInterface = new Interface(hardhat.artifacts.readArtifactSync("Governance").abi);

const provider = web3Provider();

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-shared-bridge-era").description("upgrade shared bridge for era diamond proxy");

  program
    .command("transfer-ownership")
    .option("--private-key <private-key>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--owner-address <owner-address>")
    .option("--validator-timelock-addr <validatorTimelockAddr>")
    .option("--stm-addr <stateTransitionManagerAddr>")
    .option("--l1-shared-bridge-addr <l1SharedBridgeAddr>")
    .option("--bridgehub-addr <bridgehubAddr>")
    .option("--proxy-admin-addr <proxyAdminAddr>")
    .option("--only-verifier")
    .action(async (cmd) => {
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const ownerAddress = ethers.utils.getAddress(cmd.ownerAddress);
      console.log(`Using owner address: ${ownerAddress}`);

      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      // Moving ownership for ValidatorTimelock
      const validatorTimelockAddr = ethers.utils.getAddress(cmd.validatorTimelockAddr);
      console.log(`Using ValidatorTimelock address: ${validatorTimelockAddr}`);
      const stmAddr = ethers.utils.getAddress(cmd.stmAddr);
      console.log("Using STM address: ", stmAddr);
      const l1SharedBridgeAddr = ethers.utils.getAddress(cmd.l1SharedBridgeAddr);
      console.log("Using L1 Shared Bridge address: ", l1SharedBridgeAddr);
      const bridgehubAddr = ethers.utils.getAddress(cmd.bridgehubAddr);
      console.log("Using Bridgehub address: ", bridgehubAddr);
      const proxyAdminAddr = ethers.utils.getAddress(cmd.proxyAdminAddr);
      console.log("Using Proxy Admin address: ", proxyAdminAddr);

      await transferOwnership1StepTo(deployWallet, validatorTimelockAddr, ownerAddress, true);
      await transferOwnership1StepTo(deployWallet, stmAddr, ownerAddress, true);
      await transferOwnership1StepTo(deployWallet, l1SharedBridgeAddr, ownerAddress, true);
      await transferOwnership1StepTo(deployWallet, bridgehubAddr, ownerAddress, true);
      await transferOwnership1StepTo(deployWallet, proxyAdminAddr, ownerAddress, false);
    });

  program
    .command("accept-ownership")
    .option("--validator-timelock-addr <validatorTimelockAddr>")
    .option("--stm-addr <stateTransitionManagerAddr>")
    .option("--l1-shared-bridge-addr <l1SharedBridgeAddr>")
    .option("--bridgehub-addr <bridgehubAddr>")
    .action(async (cmd) => {
      // Moving ownership for ValidatorTimelock
      const validatorTimelockAddr = ethers.utils.getAddress(cmd.validatorTimelockAddr);
      console.log(`Using ValidatorTimelock address: ${validatorTimelockAddr}`);
      const stmAddr = ethers.utils.getAddress(cmd.stmAddr);
      console.log("Using STM address: ", stmAddr);
      const l1SharedBridgeAddr = ethers.utils.getAddress(cmd.l1SharedBridgeAddr);
      console.log("Using L1 Shared Bridge address: ", l1SharedBridgeAddr);
      const bridgehubAddr = ethers.utils.getAddress(cmd.bridgehubAddr);
      console.log("Using Bridgehub address: ", bridgehubAddr);

      const addresses = [validatorTimelockAddr, stmAddr, l1SharedBridgeAddr, bridgehubAddr];

      const govCalls = addresses.map(acceptOwnershipCall);

      const govOperation = {
        calls: govCalls,
        predecessor: ethers.constants.HashZero,
        salt: ethers.constants.HashZero,
      };

      const scheduleData = governanceInterface.encodeFunctionData("scheduleTransparent", [govOperation, 0]);
      const executeData = governanceInterface.encodeFunctionData("execute", [govOperation]);

      console.log("Calldata for scheduling: ", scheduleData);
      console.log("Calldata for execution: ", executeData);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });

async function transferOwnership1StepTo(
  wallet: ethers.Wallet,
  contractAddress: string,
  newOwner: string,
  printPendingOwner: boolean = true
) {
  const contract = new ethers.Contract(contractAddress, ownable2StepInterface, wallet);
  console.log("Transferring ownership of contract: ", contractAddress, " to: ", newOwner);
  const tx = await contract.transferOwnership(newOwner);
  console.log("Tx hash", tx.hash);
  await tx.wait();
  if (printPendingOwner) {
    const newPendingOwner = await contract.pendingOwner();
    console.log("New pending owner: ", newPendingOwner);
  }
}

function acceptOwnershipCall(target: string) {
  const data = ownable2StepInterface.encodeFunctionData("acceptOwnership", []);
  return {
    target,
    value: 0,
    data,
  };
}
