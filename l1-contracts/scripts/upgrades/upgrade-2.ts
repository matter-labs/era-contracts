// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import { Command } from "commander";
import { diamondCut } from "../../src.ts/diamondCut";
import type { BigNumberish } from "ethers";
import { Wallet } from "ethers";
import { ethers } from "hardhat";
import { Provider } from "zksync-ethers";
import "@nomiclabs/hardhat-ethers";
import { web3Provider } from "../utils";
import { Deployer } from "../../src.ts/deploy";
import { ethTestConfig } from "../../src.ts/utils";

type ForceDeployment = {
  bytecodeHash: string;
  newAddress: string;
  value: BigNumberish;
  input: string;
};

function sleep(millis: number) {
  return new Promise((resolve) => setTimeout(resolve, millis));
}

async function prepareCalldata(
  diamondUpgradeAddress: string,
  deployerBytecodeHash: string,
  params: Array<ForceDeployment>
) {
  const DiamondUpgradeInit2 = await ethers.getContractAt("DiamondUpgradeInit2", ZERO_ADDRESS);
  const oldDeployerSystemContract = await ethers.getContractAt("IOldContractDeployer", ZERO_ADDRESS);
  const newDeployerSystemContract = await ethers.getContractAt("IContractDeployer", ZERO_ADDRESS);

  const upgradeDeployerCalldata = await oldDeployerSystemContract.interface.encodeFunctionData("forceDeployOnAddress", [
    deployerBytecodeHash,
    DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
    "0x",
  ]);
  const upgradeSystemContractsCalldata = await newDeployerSystemContract.interface.encodeFunctionData(
    "forceDeployOnAddresses",
    [params]
  );

  // Prepare the diamond cut data
  const upgradeInitData = await DiamondUpgradeInit2.interface.encodeFunctionData("forceDeploy2", [
    upgradeDeployerCalldata,
    upgradeSystemContractsCalldata,
    [], // Empty factory deps
  ]);

  return diamondCut([], diamondUpgradeAddress, upgradeInitData);
}

const provider = web3Provider();

const ZERO_ADDRESS = ethers.constants.AddressZero;
const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";

async function main() {
  const program = new Command();

  program.version("0.1.0").name("force-deploy-upgrade-2");

  program
    .command("prepare-calldata")
    .requiredOption("--diamond-upgrade-address <diamond-upgrade-address>")
    .requiredOption("--new-deployer-bytecodehash <new-deployer-bytecodehash>")
    .requiredOption("--deployment-params <deployment-params>")
    .action(async (cmd) => {
      // Get address of the diamond init contract
      const diamondUpgradeAddress = cmd.diamondUpgradeAddress;
      // Get new deployer bytecodehash
      const deployerBytecodeHash = cmd.newDeployerBytecodehash;
      // Encode data for the upgrade call
      const params: Array<ForceDeployment> = JSON.parse(cmd.deploymentParams);
      // Get diamond cut data
      const calldata = await prepareCalldata(diamondUpgradeAddress, deployerBytecodeHash, params);
      console.log(calldata);
    });

  program
    .command("force-upgrade")
    .option("--private-key <private-key>")
    .requiredOption("--diamond-upgrade-address <diamond-upgrade-address>")
    .requiredOption("--new-deployer-bytecodehash <new-deployer-bytecodehash>")
    .requiredOption("--deployment-params <deployment-params>")
    .action(async (cmd) => {
      const zksProvider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);

      const deployer = new Deployer({
        deployWallet,
        ownerAddress: ZERO_ADDRESS,
        verbose: true,
      });
      const zkSyncContract = deployer.bridgehubContract(deployWallet);

      // Get address of the diamond init contract
      const diamondUpgradeAddress = cmd.diamondUpgradeAddress;
      // Get new deployer bytecodehash
      const deployerBytecodeHash = cmd.newDeployerBytecodehash;
      // Encode data for the upgrade call
      const params: Array<ForceDeployment> = JSON.parse(cmd.deploymentParams);
      // Get diamond cut data
      const upgradeParam = await prepareCalldata(diamondUpgradeAddress, deployerBytecodeHash, params);

      const proposeUpgradeTx = await zkSyncContract.proposeDiamondCut(upgradeParam.facetCuts, upgradeParam.initAddress);
      await proposeUpgradeTx.wait();

      const executeUpgradeTx = await zkSyncContract.executeDiamondCutProposal(upgradeParam);
      const executeUpgradeRec = await executeUpgradeTx.wait();
      const deployL2TxHashes = executeUpgradeRec.events
        .filter((event) => event.event === "NewPriorityRequest")
        .map((event) => event.args[1]);
      for (const txHash of deployL2TxHashes) {
        console.log(txHash);
        let receipt = null;
        while (receipt == null) {
          receipt = await zksProvider.getTransactionReceipt(txHash);
          await sleep(100);
        }

        if (receipt.status != 1) {
          throw new Error("Failed to process L2 tx");
        }
      }
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
