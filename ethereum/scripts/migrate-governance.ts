/// Temporary script that generated the needed calldata for the migration of the governance.

import { Command } from "commander";
import { BigNumber, ethers, Wallet } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { applyL1ToL2Alias, getAddressFromEnv, getNumberFromEnv, web3Provider } from "./utils";
import * as hre from "hardhat";
import * as fs from "fs";

import { getL1TxInfo } from "../../zksync/src/utils";

import { UpgradeableBeaconFactory } from "../../zksync/typechain/UpgradeableBeaconFactory";

const provider = web3Provider();
const priorityTxMaxGasLimit = BigNumber.from(getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT"));

const L2ERC20BridgeABI = JSON.parse(
  fs
    .readFileSync(
      "../zksync/artifacts-zk/cache-zk/solpp-generated-contracts/bridge/L2ERC20Bridge.sol/L2ERC20Bridge.json"
    )
    .toString()
).abi;

interface TxInfo {
  data: string;
  to: string;
  value?: string;
}

async function getERC20BeaconAddress(erc20BridgeAddress: string) {
  const contract = new ethers.Contract(erc20BridgeAddress, L2ERC20BridgeABI, provider);
  return await contract.l2TokenBeacon();
}

function displayTx(msg: string, info: TxInfo) {
  console.log(msg);
  console.log(JSON.stringify(info, null, 2), "\n");
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("migrate-governance");

  program
    .option("--new-governance-address <new-governance-address>")
    .option("--gas-price <gas-price>")
    .option("--refund-recipient <refund-recipient>")
    .action(async (cmd) => {
      const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, "gwei") : await provider.getGasPrice();
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const refundRecipient = cmd.refundRecipient;
      console.log(`Using refund recipient: ${refundRecipient}`);

      // This action is very dangerous, and so we double check that the governance in env is the same
      // one as the user provided manually.
      const governanceAddressFromEnv = getAddressFromEnv("CONTRACTS_GOVERNANCE_ADDR").toLowerCase();
      const userProvidedAddress = cmd.newGovernanceAddress.toLowerCase();
      if (governanceAddressFromEnv !== userProvidedAddress) {
        throw new Error("Governance mismatch");
      }

      // We won't be making any transactions with this wallet, we just need
      // it to initialize the Deployer object.
      const deployWallet = Wallet.createRandom();
      const deployer = new Deployer({
        deployWallet,
        verbose: true,
      });

      const expectedDeployedBytecode = hre.artifacts.readArtifactSync("Governance").deployedBytecode;

      const isBytecodeCorrect =
        (await provider.getCode(userProvidedAddress)).toLowerCase() === expectedDeployedBytecode.toLowerCase();
      if (!isBytecodeCorrect) {
        throw new Error("The address does not contain governance bytecode");
      }

      console.log("Firstly, the current governor should transfer its ownership to the new governance contract.");
      console.log("All the transactions below can be executed in one batch");

      // Step 1. Transfer ownership of all the contracts to the new governor.
      
      // Below we are preparing the calldata for the L1 transactions
      const zkSync = deployer.zkSyncContract(deployWallet);
      const allowlist = deployer.l1AllowList(deployWallet);
      const validatorTimelock = deployer.validatorTimelock(deployWallet);

      const erc20Bridge = deployer.transparentUpgradableProxyContract(
        deployer.addresses.Bridges.ERC20BridgeProxy,
        deployWallet
      );

      const erc20MigrationTx = erc20Bridge.interface.encodeFunctionData("changeAdmin", [governanceAddressFromEnv]);
      displayTx("ERC20 migration calldata:", {
        data: erc20MigrationTx,
        to: erc20Bridge.address,
      });

      const zkSyncSetPendingGovernor = zkSync.interface.encodeFunctionData("setPendingGovernor", [
        governanceAddressFromEnv,
      ]);
      displayTx("zkSync Diamond Proxy migration calldata:", {
        data: zkSyncSetPendingGovernor,
        to: zkSync.address,
      });

      const allowListGovernorMigration = allowlist.interface.encodeFunctionData("transferOwnership", [
        governanceAddressFromEnv,
      ]);
      displayTx("AllowList migration calldata:", {
        data: allowListGovernorMigration,
        to: allowlist.address,
      });

      const validatorTimelockMigration = validatorTimelock.interface.encodeFunctionData("transferOwnership", [
        governanceAddressFromEnv,
      ]);
      displayTx("Validator timelock migration calldata:", {
        data: validatorTimelockMigration,
        to: validatorTimelock.address,
      });

      // Below, we prepare the transactions to migrate the L2 contracts.

      // Note that since these are L2 contracts, the governance must be aliased.
      const aliasedNewGovernor = applyL1ToL2Alias(governanceAddressFromEnv);

      // L2 ERC20 bridge as well as Weth token are a transparent upgradable proxy.
      const l2Erc20BridgeCalldata = erc20Bridge.interface.encodeFunctionData("changeAdmin", [aliasedNewGovernor]);
      const l2TxForErc20Bridge = await getL1TxInfo(
        deployer,
        erc20Bridge.address,
        l2Erc20BridgeCalldata,
        refundRecipient,
        gasPrice,
        priorityTxMaxGasLimit,
        provider
      );
      displayTx("L2 ERC20 bridge changeAdmin: ", l2TxForErc20Bridge);

      const wethToken = deployer.transparentUpgradableProxyContract(
        process.env.CONTRACTS_L1_WETH_TOKEN_ADDR!,
        deployWallet
      );
      const l2WethUpgradeCalldata = wethToken.interface.encodeFunctionData("changeAdmin", [aliasedNewGovernor]);
      const l2TxForWethUpgrade = await getL1TxInfo(
        deployer,
        wethToken.address,
        l2WethUpgradeCalldata,
        refundRecipient,
        gasPrice,
        priorityTxMaxGasLimit,
        provider
      );
      displayTx("L2 Weth upgrade: ", l2TxForWethUpgrade);

      // L2 Tokens are BeaconProxies
      const beaconAddress: string = await getERC20BeaconAddress(erc20Bridge.address);
      const erc20TokenBeacon = UpgradeableBeaconFactory.connect(beaconAddress, deployWallet);
      const l2Erc20BeaconCalldata = erc20TokenBeacon.interface.encodeFunctionData("transferOwnership", [
        aliasedNewGovernor,
      ]);
      const l2TxForErc20Upgrade = await getL1TxInfo(
        deployer,
        beaconAddress,
        l2Erc20BeaconCalldata,
        refundRecipient,
        gasPrice,
        priorityTxMaxGasLimit,
        provider
      );
      displayTx("L2 ERC20 beacon upgrade: ", l2TxForErc20Upgrade);

      // Small delimeter for better readability.
      console.log("\n\n\n", "-".repeat(20), "\n\n\n");

      console.log("Secondly, the new governor needs to accept all the roles where they need to be accepted.");

      // Step 2. Accept the roles on L1. Transparent proxy and Beacon proxy contracts do NOT require accepting new ownership.
      // However, the following do require:
      // - zkSync Diamond Proxy
      // - ValidatorTimelock.
      // - Allowlist.

      const calls = [
        {
          target: zkSync.address,
          value: 0,
          data: zkSync.interface.encodeFunctionData("acceptGovernor"),
        },
        {
          target: allowlist.address,
          value: 0,
          data: allowlist.interface.encodeFunctionData("acceptOwnership"),
        },
        {
          target: validatorTimelock.address,
          value: 0,
          data: validatorTimelock.interface.encodeFunctionData("acceptOwnership"),
        },
      ];

      const operation = {
        calls: calls,
        predecessor: ethers.constants.HashZero,
        salt: ethers.constants.HashZero,
      };

      const governance = deployer.governanceContract(deployWallet);

      const scheduleTransparentCalldata = governance.interface.encodeFunctionData("scheduleTransparent", [
        operation,
        0,
      ]);
      displayTx("Schedule transparent calldata:\n", {
        data: scheduleTransparentCalldata,
        to: governance.address,
      });

      const executeCalldata = governance.interface.encodeFunctionData("execute", [operation]);
      displayTx("Execute calldata:\n", {
        data: executeCalldata,
        to: governance.address,
      });
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
