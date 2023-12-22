import { Command } from "commander";
import { diamondCut } from "../../src.ts/diamondCut";
import { Wallet } from "ethers";
import { ethers } from "hardhat";
import { Provider } from "zksync-ethers";
import "@nomicfoundation/hardhat-ethers";
import { web3Provider } from "../utils";
import { Deployer } from "../../src.ts/deploy";
import * as fs from "fs";
import * as path from "path";
import { IOldDiamondCut__factory } from "../../typechain-types";

function sleep(millis: number) {
  return new Promise((resolve) => setTimeout(resolve, millis));
}

async function prepareCalldata(
  diamondUpgradeAddress: string,
  allowlist: string,
  verifier: string,
  prioirityTxMaxGasLimit: string
) {
  const DiamondUpgradeInit3 = await ethers.getContractAt("DiamondUpgradeInit3", ZERO_ADDRESS);

  // Prepare the diamond cut data
  const upgradeInitData = await DiamondUpgradeInit3.interface.encodeFunctionData("upgrade", [
    allowlist,
    verifier,
    prioirityTxMaxGasLimit,
  ]);

  return diamondCut([], diamondUpgradeAddress, upgradeInitData);
}

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

const ZERO_ADDRESS = ethers.ZeroAddress;

async function main() {
  const program = new Command();

  program.version("0.1.0").name("force-deploy-upgrade-2");

  program
    .command("prepare-calldata")
    .requiredOption("--diamond-upgrade-address <diamond-upgrade-address>")
    .requiredOption("--allowlist-address <allowlist>")
    .requiredOption("--verifier-address <verifier>")
    .requiredOption("--prioirity-tx-max-gas-limit <prioirity-tx-max-gas-limit>")
    .action(async (cmd) => {
      // Get address of the diamond init contract
      const diamondUpgradeAddress = cmd.diamondUpgradeAddress;
      // Get address of the allowlist contract
      const allowlist = cmd.allowlistAddress;
      // Get address of the verifier contract
      const verifier = cmd.verifierAddress;
      // Get the prioirity tx max L2 gas limit
      const prioirityTxMaxGasLimit = cmd.prioirityTxMaxGasLimit;
      // Get diamond cut data
      const calldata = await prepareCalldata(diamondUpgradeAddress, allowlist, verifier, prioirityTxMaxGasLimit);
      console.log(calldata);
    });

  program
    .command("force-upgrade")
    .option("--private-key <private-key>")
    .option("--proposal-id <proposal-id>")
    .requiredOption("--diamond-upgrade-address <diamond-upgrade-address>")
    .requiredOption("--allowlist-address <allowlist>")
    .requiredOption("--verifier-address <verifier>")
    .requiredOption("--prioirity-tx-max-gas-limit <prioirity-tx-max-gas-limit>")
    .action(async (cmd) => {
      const zksProvider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromPhrase(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic
          ).derivePath("m/44'/60'/0'/0/1").connect(provider);

      const deployer = new Deployer({
        deployWallet,
        ownerAddress: ZERO_ADDRESS,
        verbose: true,
      });

      const zkSyncContract = IOldDiamondCut__factory.connect(deployer.addresses.ZkSync.DiamondProxy, deployWallet);

      // Get address of the diamond init contract
      const diamondUpgradeAddress = cmd.diamondUpgradeAddress;
      // Get address of the allowlist contract
      const allowlist = cmd.allowlistAddress;
      // Get address of the verifier contract
      const verifier = cmd.verifierAddress;
      // Get the prioirity tx max L2 gas limit
      const prioirityTxMaxGasLimit = cmd.prioirityTxMaxGasLimit;
      // Get diamond cut data
      const upgradeParam = await prepareCalldata(diamondUpgradeAddress, allowlist, verifier, prioirityTxMaxGasLimit);

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
