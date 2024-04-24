import * as hre from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { Command } from "commander";
import { Wallet, ethers, BigNumber } from "ethers";
import { Provider } from "zksync-web3";
import { getNumberFromEnv } from "../../l1-contracts/src.ts/utils";
import { web3Provider } from "../../l1-contracts/scripts/utils";
import { Deployer } from "../../l1-contracts/src.ts/deploy";
import { getL1TxInfo } from "./utils";
import { ethTestConfig } from "./deploy-shared-bridge-on-l2-through-l1";

// From openzeppelin-upgradable v4.9.5 Initializable contract implementation.
const INITIALIZED_STORAGE_SLOT = 0;
const priorityTxMaxGasLimit = BigNumber.from(getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT"));
const provider = web3Provider();

async function getReinitializeTokenCalldata(
  newName: string,
  newSymbol: string,
  ignoreNameGetter: boolean,
  ignoreSymbolGetter: boolean,
  ignoreDecimalsGetter: boolean,
  version: ethers.BigNumberish
) {
  const l2StandardERC20Artifact = await hre.artifacts.readArtifact("L2StandardERC20");
  const l2StandardERC20Interface = new ethers.utils.Interface(l2StandardERC20Artifact.abi);

  const availableGetters = {
    ignoreName: ignoreNameGetter,
    ignoreSymbol: ignoreSymbolGetter,
    ignoreDecimals: ignoreDecimalsGetter,
  };

  console.log("Using the following arguments:");
  console.log(`availableGetters = ${JSON.stringify(availableGetters, null, 4)}`);
  console.log(`newName = "${newName}"`);
  console.log(`newSymbol = "${newSymbol}"`);
  console.log(`version = ${version}\n`);

  return l2StandardERC20Interface.encodeFunctionData("reinitializeToken", [
    availableGetters,
    newName,
    newSymbol,
    version,
  ]);
}

async function getReinitializeTokenTxInfo(
  deployer: Deployer,
  refundRecipient: string,
  gasPrice: BigNumber,
  tokenAddress: string,
  newName: string,
  newSymbol: string,
  ignoreNameGetter: boolean,
  ignoreSymbolGetter: boolean,
  ignoreDecimalsGetter: boolean,
  version: ethers.BigNumberish
) {
  const l2Calldata = await getReinitializeTokenCalldata(
    newName,
    newSymbol,
    ignoreNameGetter,
    ignoreSymbolGetter,
    ignoreDecimalsGetter,
    version
  );
  return await getL1TxInfo(
    deployer,
    tokenAddress,
    l2Calldata,
    refundRecipient,
    gasPrice,
    priorityTxMaxGasLimit,
    provider
  );
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("update-l2-erc20-metadata");

  program
    .option("--token-address <upgrades-info>")
    .option("--gas-price <gas-price>")
    .option("--deployer-private-key <deployer-private-key>")
    .option("--refund-recipient <refund-recipient>")
    .option("--new-name <new-name>")
    .option("--new-symbol <new-symbol>")
    .option("--ignore-name-getter")
    .option("--ignore-symbol-getter")
    .option("--ignore-decimals-getter")
    .option("--reinitialization-version <version>")
    .action(async (cmd) => {
      const gasPrice = cmd.gasPrice
        ? ethers.utils.parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(3).div(2);
      const deployWallet = cmd.deployerPrivateKey
        ? new Wallet(cmd.deployerPrivateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      const deployer = new Deployer({ deployWallet });
      const refundRecipient = cmd.refundRecipient ? cmd.refundRecipient : deployWallet.address;
      console.log("Gas price: ", ethers.utils.formatUnits(gasPrice, "gwei"));
      console.log(
        "IMPORTANT: gasPrice that you provide in the transaction should be <= to the one provided to this tool."
      );

      console.log("Refund recipient: ", refundRecipient);

      const tokenAddress = cmd.tokenAddress;
      const newName = cmd.newName;
      const newSymbol = cmd.newSymbol;
      const ignoreNameGetter = cmd.ignoreNameGetter ?? false;
      const ignoreSymbolGetter = cmd.ignoreSymbolGetter ?? false;
      const ignoreDecimalsGetter = cmd.ignoreDecimalsGetter ?? false;

      let version;
      if (cmd.reinitializationVersion === undefined) {
        const provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
        const initializableStorageValue = BigNumber.from(
          await provider.getStorageAt(tokenAddress, INITIALIZED_STORAGE_SLOT)
        );

        // currently, it's saved in the first `uint8` variable, so should be stored in the lowest byte
        const initializedValue = initializableStorageValue.mod(BigNumber.from(2).pow(8));
        version = initializedValue.add(1);
      } else {
        version = parseInt(cmd.reinitializationVersion);
      }

      if (newName && ignoreNameGetter) {
        console.log("\x1b[31mWarning: ignore name getter flag used while new name is not empty\x1b[0m");
      }
      if (newSymbol && ignoreSymbolGetter) {
        console.log("\x1b[31mWarning: ignore symbol getter flag used while new symbol is not empty\x1b[0m");
      }

      const governanceCall = await getReinitializeTokenTxInfo(
        deployer,
        refundRecipient,
        gasPrice,
        tokenAddress,
        newName,
        newSymbol,
        ignoreNameGetter,
        ignoreSymbolGetter,
        ignoreDecimalsGetter,
        version
      );

      const operation = {
        calls: [governanceCall],
        predecessor: ethers.constants.HashZero,
        salt: ethers.constants.HashZero,
      };

      console.log("Governance calls: ");
      console.log(JSON.stringify(operation, null, 4) + "\n");

      const governance = deployer.governanceContract(deployWallet);
      const scheduleTransparentCalldata = governance.interface.encodeFunctionData("scheduleTransparent", [
        operation,
        0,
      ]);
      const executeCalldata = governance.interface.encodeFunctionData("execute", [operation]);

      console.log("scheduleTransparentCalldata: ");
      console.log(scheduleTransparentCalldata);

      console.log("executeCalldata: ");
      console.log(executeCalldata);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
