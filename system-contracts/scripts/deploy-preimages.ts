// hardhat import should be the first import in the file
import * as hre from "hardhat";

import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { Command } from "commander";
import type { BigNumber, BytesLike } from "ethers";
import { ethers } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import * as fs from "fs";
import * as path from "path";
import type { types } from "zksync-web3";
import { Provider, Wallet } from "zksync-web3";
import { hashBytecode } from "zksync-web3/build/src/utils";
import { Language, SYSTEM_CONTRACTS } from "./constants";
import type { Dependency, DeployedDependency } from "./utils";
import { checkMarkers, filterPublishedFactoryDeps, getBytecodes, publishFactoryDeps, readYulBytecode } from "./utils";

const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

// Maximum length of the combined length of dependencies
const MAX_COMBINED_LENGTH = 125000;

const DEFAULT_ACCOUNT_CONTRACT_NAME = "DefaultAccount";
const BOOTLOADER_CONTRACT_NAME = "Bootloader";

const CONSOLE_COLOR_RESET = "\x1b[0m";
const CONSOLE_COLOR_RED = "\x1b[31m";
const CONSOLE_COLOR_GREEN = "\x1b[32m";

interface TransactionReport {
  msg: string;
  success: boolean;
}

class PublishReporter {
  // Promises for pending L1->L2 transactions with submitted bytecode hashes.
  // Each promise will return either string with error or null denoting success.
  pendingPromises: Promise<TransactionReport>[] = [];

  async appendPublish(bytecodes: BytesLike[], deployer: Deployer, transaction: types.PriorityOpResponse) {
    const waitAndDoubleCheck = async () => {
      // Waiting for the transaction to be processed by the server
      await transaction.wait();

      // Double checking that indeed the dependencies have been marked as known
      await checkMarkers(bytecodes, deployer);
    };

    this.pendingPromises.push(
      waitAndDoubleCheck()
        .catch((err) => {
          return Promise.resolve({
            msg: `Transaction ${transaction.hash} failed with ${err.message || err}`,
            success: false,
          });
        })
        .then(() => {
          return Promise.resolve({
            msg: `Transaction ${transaction.hash} was successful`,
            success: true,
          });
        })
    );
  }

  async report() {
    const results = await Promise.all(this.pendingPromises);
    results.forEach((result) => {
      if (result.success) {
        console.log(CONSOLE_COLOR_GREEN + result.msg + CONSOLE_COLOR_RESET);
      } else {
        console.log(CONSOLE_COLOR_RED + result.msg + CONSOLE_COLOR_RESET);
      }
    });
  }
}

class ZkSyncDeployer {
  deployer: Deployer;
  gasPrice: BigNumber;
  nonce: number;
  dependenciesToUpgrade: DeployedDependency[];
  defaultAccountToUpgrade?: DeployedDependency;
  bootloaderToUpgrade?: DeployedDependency;
  reporter: PublishReporter;
  constructor(deployer: Deployer, gasPrice: BigNumber, nonce: number) {
    this.deployer = deployer;
    this.gasPrice = gasPrice;
    this.nonce = nonce;
    this.dependenciesToUpgrade = [];
    this.reporter = new PublishReporter();
  }

  async publishFactoryDeps(dependencies: Dependency[]) {
    if (dependencies.length === 0) {
      return;
    }

    const priorityOpHandle = await publishFactoryDeps(dependencies, this.deployer, this.nonce, this.gasPrice);

    await this.reporter.appendPublish(getBytecodes(dependencies), this.deployer, priorityOpHandle);
    this.nonce += 1;
  }

  // Returns the current default account bytecode on zkSync
  async currentDefaultAccountBytecode(): Promise<string> {
    const zkSync = await this.deployer.zkWallet.getMainContract();
    return await zkSync.getL2DefaultAccountBytecodeHash();
  }

  // If needed, appends the default account bytecode to the upgrade
  async checkShouldUpgradeDefaultAA(defaultAccountBytecode: string) {
    const bytecodeHash = ethers.utils.hexlify(hashBytecode(defaultAccountBytecode));
    const currentDefaultAccountBytecode = ethers.utils.hexlify(await this.currentDefaultAccountBytecode());

    // If the bytecode is not the same as the one deployed on zkSync, we need to add it to the deployment
    if (bytecodeHash.toLowerCase() !== currentDefaultAccountBytecode) {
      this.defaultAccountToUpgrade = {
        name: DEFAULT_ACCOUNT_CONTRACT_NAME,
        bytecodeHashes: [bytecodeHash],
      };
    }
  }

  // Publish default account bytecode
  async publishDefaultAA(defaultAccountBytecode: string) {
    const [defaultAccountBytecodes] = await filterPublishedFactoryDeps(
      DEFAULT_ACCOUNT_CONTRACT_NAME,
      [defaultAccountBytecode],
      this.deployer
    );

    if (defaultAccountBytecodes.length == 0) {
      console.log("Default account bytecode is already published, skipping");
      return;
    }

    await this.publishFactoryDeps([
      {
        name: DEFAULT_ACCOUNT_CONTRACT_NAME,
        bytecodes: defaultAccountBytecodes,
      },
    ]);
  }

  // Publishes the bytecode of default AA and appends it to the deployed bytecodes if needed.
  async processDefaultAA() {
    const defaultAccountBytecode = (await this.deployer.loadArtifact(DEFAULT_ACCOUNT_CONTRACT_NAME)).bytecode;

    await this.publishDefaultAA(defaultAccountBytecode);
    await this.checkShouldUpgradeDefaultAA(defaultAccountBytecode);
  }

  async currentBootloaderBytecode(): Promise<string> {
    const zkSync = await this.deployer.zkWallet.getMainContract();
    return await zkSync.getL2BootloaderBytecodeHash();
  }

  async checkShouldUpgradeBootloader(bootloaderCode: string) {
    const bytecodeHash = ethers.utils.hexlify(hashBytecode(bootloaderCode));
    const currentBootloaderBytecode = ethers.utils.hexlify(await this.currentBootloaderBytecode());

    // If the bytecode is not the same as the one deployed on zkSync, we need to add it to the deployment
    if (bytecodeHash.toLowerCase() !== currentBootloaderBytecode) {
      this.bootloaderToUpgrade = {
        name: BOOTLOADER_CONTRACT_NAME,
        bytecodeHashes: [bytecodeHash],
      };
    }
  }

  async publishBootloader(bootloaderCode: string) {
    console.log("\nPublishing bootloader bytecode:");

    const [deps] = await filterPublishedFactoryDeps(BOOTLOADER_CONTRACT_NAME, [bootloaderCode], this.deployer);

    if (deps.length == 0) {
      console.log("Default bootloader bytecode is already published, skipping");
      return;
    }

    await this.publishFactoryDeps([
      {
        name: BOOTLOADER_CONTRACT_NAME,
        bytecodes: deps,
      },
    ]);
  }

  async processBootloader() {
    const bootloaderCode = ethers.utils.hexlify(fs.readFileSync("./bootloader/build/artifacts/proved_batch.yul.zbin"));

    await this.publishBootloader(bootloaderCode);
    await this.checkShouldUpgradeBootloader(bootloaderCode);
  }

  async shouldUpgradeSystemContract(contractAddress: string, expectedBytecodeHash: string): Promise<boolean> {
    // We could have also used the `getCode` method of the JSON-RPC, but in the context
    // of system upgrades looking into account code storage is more robust
    const currentBytecodeHash = await this.deployer.zkWallet.provider.getStorageAt(
      SYSTEM_CONTRACTS.accountCodeStorage.address,
      contractAddress
    );

    return expectedBytecodeHash.toLowerCase() !== currentBytecodeHash.toLowerCase();
  }

  // Returns the contracts to be published.
  async prepareContractsForPublishing(): Promise<Dependency[]> {
    const dependenciesToPublish: Dependency[] = [];
    for (const contract of Object.values(SYSTEM_CONTRACTS)) {
      const contractName = contract.codeName;
      let factoryDeps: string[] = [];
      if (contract.lang == Language.Solidity) {
        const artifact = await this.deployer.loadArtifact(contractName);
        factoryDeps = [...(await this.deployer.extractFactoryDeps(artifact)), artifact.bytecode];
      } else {
        // Yul files have only one dependency
        factoryDeps = [readYulBytecode(contract)];
      }

      const contractBytecodeHash = ethers.utils.hexlify(hashBytecode(factoryDeps[factoryDeps.length - 1]));
      if (await this.shouldUpgradeSystemContract(contract.address, contractBytecodeHash)) {
        this.dependenciesToUpgrade.push({
          name: contractName,
          bytecodeHashes: [contractBytecodeHash],
          address: contract.address,
        });
      }

      const [bytecodesToPublish, currentLength] = await filterPublishedFactoryDeps(
        contractName,
        factoryDeps,
        this.deployer
      );
      if (bytecodesToPublish.length == 0) {
        console.log(`All bytecodes for ${contractName} are already published, skipping`);
        continue;
      }
      if (currentLength > MAX_COMBINED_LENGTH) {
        throw new Error(`Can not publish dependencies of contract ${contractName}`);
      }

      dependenciesToPublish.push({
        name: contractName,
        bytecodes: bytecodesToPublish,
        address: contract.address,
      });
    }

    return dependenciesToPublish;
  }

  async publishDependencies(dependenciesToPublish: Dependency[]) {
    let currentLength = 0;
    let currentDependencies: Dependency[] = [];
    // We iterate over dependencies and try to batch the publishing of those in order to save up on gas as well as time.
    for (const dependency of dependenciesToPublish) {
      const dependencyLength = dependency.bytecodes.reduce((prev, dep) => prev + ethers.utils.arrayify(dep).length, 0);
      if (currentLength + dependencyLength > MAX_COMBINED_LENGTH) {
        await this.publishFactoryDeps(currentDependencies);
        currentLength = dependencyLength;
        currentDependencies = [dependency];
      } else {
        currentLength += dependencyLength;
        currentDependencies.push(dependency);
      }
    }
    if (currentDependencies.length > 0) {
      await this.publishFactoryDeps(currentDependencies);
    }
  }

  returnResult() {
    return {
      systemContracts: this.dependenciesToUpgrade,
      defaultAA: this.defaultAccountToUpgrade,
      bootloader: this.bootloaderToUpgrade,
    };
  }
}

export function l1RpcUrl() {
  return process.env.ETH_CLIENT_WEB3_URL as string;
}

export function l2RpcUrl() {
  return process.env.API_WEB3_JSON_RPC_HTTP_URL as string;
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("publish preimages").description("publish preimages for the L2 contracts");

  program
    .option("--private-key <private-key>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--l1Rpc <l1Rpc>")
    .option("--l2Rpc <l2Rpc>")
    .option("--bootloader")
    .option("--default-aa")
    .option("--system-contracts")
    .option("--file <file>")
    .action(async (cmd) => {
      const l1Rpc = cmd.l1Rpc ? cmd.l1Rpc : l1RpcUrl();
      const l2Rpc = cmd.l2Rpc ? cmd.l2Rpc : l2RpcUrl();
      const providerL1 = new ethers.providers.JsonRpcProvider(l1Rpc);
      const providerL2 = new Provider(l2Rpc);
      const wallet = cmd.privateKey
        ? new Wallet(cmd.privateKey)
        : Wallet.fromMnemonic(process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic, "m/44'/60'/0'/0/1");
      wallet.connect(providerL2);
      wallet.connectToL1(providerL1);

      // TODO(EVM-392): refactor to avoid `any` here.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const deployer = new Deployer(hre, wallet as any);
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      deployer.zkWallet = deployer.zkWallet.connect(providerL2 as any).connectToL1(providerL1);
      deployer.ethWallet = deployer.ethWallet.connect(providerL1);
      const ethWallet = deployer.ethWallet;

      console.log(`Using deployer wallet: ${ethWallet.address}`);

      const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, "gwei") : await providerL1.getGasPrice();
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await ethWallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      const zkSyncDeployer = new ZkSyncDeployer(deployer, gasPrice, nonce);
      if (cmd.bootloader) {
        await zkSyncDeployer.processBootloader();
      }

      if (cmd.defaultAa) {
        await zkSyncDeployer.processDefaultAA();
      }

      if (cmd.systemContracts) {
        const dependenciesToPublish = await zkSyncDeployer.prepareContractsForPublishing();
        await zkSyncDeployer.publishDependencies(dependenciesToPublish);
      }

      console.log("\nSending all L1->L2 transactions done. Now waiting for the reports on those...\n");
      await zkSyncDeployer.reporter.report();

      const result = zkSyncDeployer.returnResult();
      console.log(JSON.stringify(result, null, 2));
      if (cmd.file) {
        fs.writeFileSync(cmd.file, JSON.stringify(result, null, 2));
      }
      console.log("\nPublishing factory dependencies complete!");
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
