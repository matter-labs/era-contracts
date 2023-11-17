import { Command } from "commander";
import { diamondCut } from "../../src.ts/diamondCut";
import type { BigNumberish } from "ethers";
import { Wallet } from "ethers";
import { ethers } from "hardhat";
import { Provider } from "zksync-web3";
import "@nomiclabs/hardhat-ethers";
import { web3Provider } from "../utils";
import { Deployer } from "../../src.ts/deploy";
import * as fs from "fs";
import * as path from "path";

type ForceDeployment = {
  bytecodeHash: string;
  newAddress: string;
  callConstructor: boolean;
  value: BigNumberish;
  input: string;
};

function sleep(millis: number) {
  return new Promise((resolve) => setTimeout(resolve, millis));
}

async function prepareCalldata(
  diamondUpgradeAddress: string,
  deployerDeployment: ForceDeployment,
  otherDeployments: Array<ForceDeployment>
) {
  const DiamondUpgradeInit5 = await ethers.getContractAt("DiamondUpgradeInit5", ZERO_ADDRESS);
  const newDeployerSystemContract = await ethers.getContractAt("IL2ContractDeployer", ZERO_ADDRESS);

  const deployerUpgradeCalldata = await newDeployerSystemContract.interface.encodeFunctionData(
    "forceDeployOnAddresses",
    [[deployerDeployment]]
  );

  const upgradeSystemContractsCalldata = await newDeployerSystemContract.interface.encodeFunctionData(
    "forceDeployOnAddresses",
    [otherDeployments]
  );

  // Prepare the diamond cut data
  const upgradeInitData = await DiamondUpgradeInit5.interface.encodeFunctionData("forceDeploy", [
    deployerUpgradeCalldata,
    upgradeSystemContractsCalldata,
    [], // Empty factory deps
  ]);

  return diamondCut([], diamondUpgradeAddress, upgradeInitData);
}

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

const ZERO_ADDRESS = ethers.constants.AddressZero;
const DEPLOYER_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";

async function getCalldata(diamondUpgradeAddress: string, params: ForceDeployment[]) {
  const deployerDeployments = params.filter(
    (deployment) => deployment.newAddress.toLowerCase() == DEPLOYER_CONTRACT_ADDRESS
  );
  if (deployerDeployments.length == 0) {
    throw new Error("Deployer contract deployment not found");
  }

  if (deployerDeployments.length != 1) {
    throw new Error("Multiple deployer contract deployments found");
  }

  const deployerDeployment = deployerDeployments[0];

  const otherDeployments = params.filter(
    (deployment) => deployment.newAddress.toLowerCase() != DEPLOYER_CONTRACT_ADDRESS
  );

  // Get diamond cut data
  return await prepareCalldata(diamondUpgradeAddress, deployerDeployment, otherDeployments);
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("force-deploy-upgrade-5");

  program
    .command("prepare-calldata")
    .requiredOption("--diamond-upgrade-address <diamond-upgrade-address>")
    .requiredOption("--deployment-params <deployment-params>")
    .action(async (cmd) => {
      // Get address of the diamond init contract
      const diamondUpgradeAddress = cmd.diamondUpgradeAddress;
      // Encode data for the upgrade call
      const params: Array<ForceDeployment> = JSON.parse(cmd.deploymentParams);

      // Get diamond cut data
      const calldata = await getCalldata(diamondUpgradeAddress, params);
      console.log(calldata);
    });

  program
    .command("force-upgrade")
    .option("--private-key <private-key>")
    .option("--proposal-id <proposal-id>")
    .requiredOption("--diamond-upgrade-address <diamond-upgrade-address>")
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
        governorAddress: ZERO_ADDRESS,
        verbose: true,
      });
      const zkSyncContract = deployer.zkSyncContract(deployWallet);

      // Get address of the diamond init contract
      const diamondUpgradeAddress = cmd.diamondUpgradeAddress;
      // Encode data for the upgrade call
      const params: Array<ForceDeployment> = JSON.parse(cmd.deploymentParams);

      // Get diamond cut data
      const upgradeParam = await getCalldata(diamondUpgradeAddress, params);

      const proposalId = cmd.proposalId ? cmd.proposalId : (await zkSyncContract.getCurrentProposalId()).add(1);
      const proposeUpgradeTx = await zkSyncContract.proposeTransparentUpgrade(upgradeParam, proposalId);
      await proposeUpgradeTx.wait();

      const executeUpgradeTx = await zkSyncContract.executeUpgrade(upgradeParam, ethers.constants.HashZero);
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
