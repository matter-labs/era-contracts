/// Temporary script that generated the needed calldata for the migration of the governance. 

import { Command } from "commander";
import { ethers, Wallet } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { getAddressFromEnv, web3Provider } from "./utils";
import * as hre from 'hardhat';

import * as fs from "fs";
import * as path from "path";
import { hashBytecode } from "zksync-web3/build/src/utils";

import { getL1TxInfo } from "../../zksync/src/upgradeL2BridgeImpl";

import { TransparentUpgradeableProxyFactory } from "../../zksync/typechain/TransparentUpgradeableProxyFactory";
import { BeaconProxyFactory } from "../../zksync/typechain/BeaconProxyFactory";

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

interface TxInfo {
    data: string;
    to: string;
    value?: string;
}

function displayTx(msg: string, info: TxInfo) {
    console.log(msg);
    console.log(JSON.stringify(info, null, 2));
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("migrate-governance");

  program
    .option("--new-governance-address <new-governance-address>")
    .option("--current-governor <current-governor>")
    .option("--is-eoa <is-eoa>")
    .option("--gas-price <gas-price>")
    .option("--refund-recipient <refund-recipient>")
    .action(async (cmd) => {
      const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, "gwei") : await provider.getGasPrice();
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      // This action is very dangerous, and so we double check that the governance in env is the same 
      // one as the user provided manually. 
      const governanceAddressFromEnv = getAddressFromEnv('CONTRACTS_GOVERNANCE_ADDR').toLowerCase();
      const userProvidedAddress = cmd.newGovernanceAddress.toLowerCase();

      if (governanceAddressFromEnv !== userProvidedAddress) {
        throw new Error('Governance mismatch');
      }

        // We won't be making any transactions with this wallet
        const deployWallet = Wallet.createRandom();
        const deployer = new Deployer({
            deployWallet,
            verbose: true,
        });

      const expectedDeployedBytecode = hre.artifacts.readArtifactSync('Governance').deployedBytecode;

      const isBytecodeCorrect = (await provider.getCode(userProvidedAddress)) != expectedDeployedBytecode;
      if(!isBytecodeCorrect) {
        throw new Error('The address does not contain governance bytecode');
      }

      const currentGovernor = cmd.currentGovernor;

      // Step 1. Migrating the L1 contracts.
      const zkSync = deployer.zkSyncContract(deployWallet);
      const allowlist = deployer.l1AllowList(deployWallet);
      const validatorTimelock = deployer.validatorTimelock(deployWallet);

      const erc20Bridge = deployer.transparentUpgradableProxyContract(
        deployer.addresses.Bridges.ERC20BridgeProxy,
        deployWallet
      );
      const wethBridge = deployer.transparentUpgradableProxyContract(
        deployer.addresses.Bridges.WethBridgeProxy,
        deployWallet
      );

      const erc20MigrationTx = erc20Bridge.interface.encodeFunctionData("changeAdmin", [governanceAddressFromEnv]);
      displayTx('ERC20 migration calldata:\n', { 
        data: erc20MigrationTx,
        to: erc20Bridge.address
      });


      const zkSyncSetPendingGovernor = zkSync.interface.encodeFunctionData("setPendingGovernor", [governanceAddressFromEnv]);
      displayTx('ERC20 migration calldata:\n', { 
        data: zkSyncSetPendingGovernor,
        to: zkSync.address
      });

      const allowListGovernorMigration = allowlist.interface.encodeFunctionData("transferOwnership", [governanceAddressFromEnv]);
        displayTx('Allowlist migration calldata:\n', { 
            data: allowListGovernorMigration,
            to: allowlist.address
        });

    const validatorTimelockMigration = validatorTimelock.interface.encodeFunctionData("transferOwnership", [governanceAddressFromEnv]);
    displayTx('Validator timelock migration calldata:\n', {
        data: validatorTimelockMigration,
        to: validatorTimelock.address   
    });

    // Step 2. Migrate the L2 contracts.

    // L2 ERC20 bridge as well as Weth token are a transparent upgradable proxy
    
    // const erc20BridgeData = await getL1TxInfo(erc20Bridge.address, provider);

       

      // Note, that we do not migrate `AllowList` contract.

      // Step 1. 

      await (await erc20Bridge.changeAdmin(governance.address)).wait();
      await (await wethBridge.changeAdmin(governance.address)).wait();

      await (await zkSync.setPendingGovernor(governance.address)).wait();

      const call = {
        target: zkSync.address,
        value: 0,
        data: zkSync.interface.encodeFunctionData("acceptGovernor"),
      };

      const operation = {
        calls: [call],
        predecessor: ethers.constants.HashZero,
        salt: ethers.constants.HashZero,
      };

      await (await governance.scheduleTransparent(operation, 0)).wait();
      await (await governance.execute(operation)).wait();
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
