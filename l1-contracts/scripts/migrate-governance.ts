/// Temporary script that generated the needed calldata for the migration of the governance.

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import { Command } from "commander";
import { BigNumber, ethers, Wallet } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import * as fs from "fs";
import { Deployer } from "../src.ts/deploy";
import { applyL1ToL2Alias, getAddressFromEnv, getNumberFromEnv } from "../src.ts/utils";
import { GAS_MULTIPLIER, web3Provider } from "./utils";

import type { TxInfo } from "../../l2-contracts/src/utils";
import { getL1TxInfo } from "../../l2-contracts/src/utils";

import { Provider } from "zksync-ethers";
import { UpgradeableBeaconFactory } from "../../l2-contracts/typechain/UpgradeableBeaconFactory";

const provider = web3Provider();
const priorityTxMaxGasLimit = BigNumber.from(getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT"));

const l2SharedBridgeABI = JSON.parse(
  fs
    .readFileSync("../l2-contracts/artifacts-zk/contracts-preprocessed/bridge/L2SharedBridge.sol/L2SharedBridge.json")
    .toString()
).abi;

async function getERC20BeaconAddress(l2SharedBridgeAddress: string) {
  const provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
  const contract = new ethers.Contract(l2SharedBridgeAddress, l2SharedBridgeABI, provider);
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
      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const refundRecipient = cmd.refundRecipient;
      console.log(`Using refund recipient: ${refundRecipient}`);

      // This action is very dangerous, and so we double check that the governance in env is the same
      // one as the user provided manually.
      const governanceAddressFromEnv = getAddressFromEnv("CONTRACTS_GOVERNANCE_ADDR").toLowerCase();
      const userProvidedAddress = cmd.newGovernanceAddress.toLowerCase();

      console.log(`Using governance address from env: ${governanceAddressFromEnv}`);
      console.log(`Using governance address from user: ${userProvidedAddress}`);

      if (governanceAddressFromEnv !== userProvidedAddress) {
        throw new Error("Governance mismatch");
      }

      // We won't be making any transactions with this wallet, we just need
      // it to initialize the Deployer object.
      const deployWallet = Wallet.createRandom().connect(
        new ethers.providers.JsonRpcProvider(process.env.ETH_CLIENT_WEB3_URL!)
      );
      const deployer = new Deployer({
        deployWallet,
        verbose: true,
      });

      const expectedDeployedBytecode = hardhat.artifacts.readArtifactSync("Governance").deployedBytecode;

      const isBytecodeCorrect =
        (await provider.getCode(userProvidedAddress)).toLowerCase() === expectedDeployedBytecode.toLowerCase();
      if (!isBytecodeCorrect) {
        throw new Error("The address does not contain governance bytecode");
      }

      console.log("Firstly, the current governor should transfer its ownership to the new governance contract.");
      console.log("All the transactions below can be executed in one batch");

      // Step 1. Transfer ownership of all the contracts to the new governor.

      // Below we are preparing the calldata for the L1 transactions
      const zkSync = deployer.stateTransitionContract(deployWallet);
      const validatorTimelock = deployer.validatorTimelock(deployWallet);

      const l1Erc20Bridge = deployer.transparentUpgradableProxyContract(
        deployer.addresses.Bridges.ERC20BridgeProxy,
        deployWallet
      );

      const erc20MigrationTx = l1Erc20Bridge.interface.encodeFunctionData("changeAdmin", [governanceAddressFromEnv]);
      displayTx("L1 ERC20 bridge migration calldata:", {
        data: erc20MigrationTx,
        target: l1Erc20Bridge.address,
      });

      const zkSyncSetPendingGovernor = zkSync.interface.encodeFunctionData("setPendingAdmin", [
        governanceAddressFromEnv,
      ]);
      displayTx("zkSync Diamond Proxy migration calldata:", {
        data: zkSyncSetPendingGovernor,
        target: zkSync.address,
      });

      const validatorTimelockMigration = validatorTimelock.interface.encodeFunctionData("transferOwnership", [
        governanceAddressFromEnv,
      ]);
      displayTx("Validator timelock migration calldata:", {
        data: validatorTimelockMigration,
        target: validatorTimelock.address,
      });

      // Below, we prepare the transactions to migrate the L2 contracts.

      // Note that since these are L2 contracts, the governance must be aliased.
      const aliasedNewGovernor = applyL1ToL2Alias(governanceAddressFromEnv);

      // L2 ERC20 bridge as well as Weth token are a transparent upgradable proxy.
      const l2SharedBridge = deployer.transparentUpgradableProxyContract(
        process.env.CONTRACTS_L2_SHARED_BRIDGE_ADDR!,
        deployWallet
      );
      const l2SharedBridgeCalldata = l2SharedBridge.interface.encodeFunctionData("changeAdmin", [aliasedNewGovernor]);
      const l2TxForErc20Bridge = await getL1TxInfo(
        deployer,
        l2SharedBridge.address,
        l2SharedBridgeCalldata,
        refundRecipient,
        gasPrice,
        priorityTxMaxGasLimit,
        provider
      );
      displayTx("L2 ERC20 bridge changeAdmin: ", l2TxForErc20Bridge);

      const l2wethToken = deployer.transparentUpgradableProxyContract(
        process.env.CONTRACTS_L2_WETH_TOKEN_PROXY_ADDR!,
        deployWallet
      );
      const l2WethUpgradeCalldata = l2wethToken.interface.encodeFunctionData("changeAdmin", [aliasedNewGovernor]);
      const l2TxForWethUpgrade = await getL1TxInfo(
        deployer,
        l2wethToken.address,
        l2WethUpgradeCalldata,
        refundRecipient,
        gasPrice,
        priorityTxMaxGasLimit,
        provider
      );
      displayTx("L2 Weth upgrade: ", l2TxForWethUpgrade);

      // L2 Tokens are BeaconProxies
      const l2Erc20BeaconAddress: string = await getERC20BeaconAddress(l2SharedBridge.address);
      const l2Erc20TokenBeacon = UpgradeableBeaconFactory.connect(l2Erc20BeaconAddress, deployWallet);
      const l2Erc20BeaconCalldata = l2Erc20TokenBeacon.interface.encodeFunctionData("transferOwnership", [
        aliasedNewGovernor,
      ]);
      const l2TxForErc20BeaconUpgrade = await getL1TxInfo(
        deployer,
        l2Erc20BeaconAddress,
        l2Erc20BeaconCalldata,
        refundRecipient,
        gasPrice,
        priorityTxMaxGasLimit,
        provider
      );
      displayTx("L2 ERC20 beacon upgrade: ", l2TxForErc20BeaconUpgrade);

      // Small delimiter for better readability.
      console.log("\n\n\n", "-".repeat(20), "\n\n\n");

      console.log("Secondly, the new governor needs to accept all the roles where they need to be accepted.");

      // Step 2. Accept the roles on L1. Transparent proxy and Beacon proxy contracts do NOT require accepting new ownership.
      // However, the following do require:
      // - zkSync Diamond Proxy
      // - ValidatorTimelock.

      const calls = [
        {
          target: zkSync.address,
          value: 0,
          data: zkSync.interface.encodeFunctionData("acceptAdmin"),
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
        target: governance.address,
      });

      const executeCalldata = governance.interface.encodeFunctionData("execute", [operation]);
      displayTx("Execute calldata:\n", {
        data: executeCalldata,
        target: governance.address,
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
