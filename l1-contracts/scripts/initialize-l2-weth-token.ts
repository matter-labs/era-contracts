import { Command } from "commander";
import { ethers, Wallet } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { Deployer } from "../src.ts/deploy";
import { getNumberFromEnv, getTokens, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, web3Provider } from "./utils";

import * as fs from "fs";
import * as path from "path";

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

const contractArtifactsPath = path.join(process.env.ZKSYNC_HOME as string, "contracts/l2-contracts/artifacts-zk/");
const l2BridgeArtifactsPath = path.join(contractArtifactsPath, "cache-zk/solpp-generated-contracts/bridge/");
const openzeppelinTransparentProxyArtifactsPath = path.join(
  contractArtifactsPath,
  "@openzeppelin/contracts/proxy/transparent/"
);

function readInterface(path: string, fileName: string, solFileName?: string) {
  solFileName ??= fileName;
  const abi = JSON.parse(fs.readFileSync(`${path}/${solFileName}.sol/${fileName}.json`, { encoding: "utf-8" })).abi;
  return new ethers.utils.Interface(abi);
}

const DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = getNumberFromEnv("CONTRACTS_DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT");
const L2_WETH_INTERFACE = readInterface(l2BridgeArtifactsPath, "L2Weth");
const TRANSPARENT_UPGRADEABLE_PROXY = readInterface(
  openzeppelinTransparentProxyArtifactsPath,
  "TransparentUpgradeableProxy",
  "TransparentUpgradeableProxy"
);

function getL2Calldata(l2WethBridgeAddress: string, l1WethTokenAddress: string, l2WethTokenImplAddress: string) {
  const upgradeData = L2_WETH_INTERFACE.encodeFunctionData("initializeV2", [l2WethBridgeAddress, l1WethTokenAddress]);
  return TRANSPARENT_UPGRADEABLE_PROXY.encodeFunctionData("upgradeToAndCall", [l2WethTokenImplAddress, upgradeData]);
}

async function getL1TxInfo(
  deployer: Deployer,
  to: string,
  l2Calldata: string,
  refundRecipient: string,
  gasPrice: ethers.BigNumber
) {
  const zksync = deployer.zkSyncContract(ethers.Wallet.createRandom().connect(provider));
  const l1Calldata = zksync.interface.encodeFunctionData("requestL2Transaction", [
    to,
    0,
    l2Calldata,
    DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    [], // It is assumed that the target has already been deployed
    refundRecipient,
  ]);

  const neededValue = await zksync.l2TransactionBaseCost(
    gasPrice,
    DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );

  return {
    to: zksync.address,
    data: l1Calldata,
    value: neededValue.toString(),
    gasPrice: gasPrice.toString(),
  };
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("initialize-l2-weth-token");

  const l2WethBridgeAddress = process.env.CONTRACTS_L2_WETH_BRIDGE_ADDR;
  const l2WethTokenProxyAddress = process.env.CONTRACTS_L2_WETH_TOKEN_PROXY_ADDR;
  const l2WethTokenImplAddress = process.env.CONTRACTS_L2_WETH_TOKEN_IMPL_ADDR;
  const tokens = getTokens(process.env.CHAIN_ETH_NETWORK || "localhost");
  const l1WethTokenAddress = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;

  program
    .command("prepare-calldata")
    .option("--private-key <private-key>")
    .option("--gas-price <gas-price>")
    .action(async (cmd) => {
      if (!l1WethTokenAddress) {
        console.log("Base Layer WETH address not provided. Skipping.");
        return;
      }

      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, "gwei") : await provider.getGasPrice();
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const deployer = new Deployer({
        deployWallet,
        verbose: true,
      });

      const l2Calldata = getL2Calldata(l2WethBridgeAddress, l1WethTokenAddress, l2WethTokenImplAddress);
      const l1TxInfo = await getL1TxInfo(
        deployer,
        l2WethTokenProxyAddress,
        l2Calldata,
        ethers.constants.AddressZero,
        gasPrice
      );
      console.log(JSON.stringify(l1TxInfo, null, 4));
      console.log("IMPORTANT: gasPrice that you provide in the transaction should be <= to the one provided above.");
    });

  program
    .command("instant-call")
    .option("--private-key <private-key>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .action(async (cmd) => {
      if (!l1WethTokenAddress) {
        console.log("Base Layer WETH address not provided. Skipping.");
        return;
      }

      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, "gwei") : await provider.getGasPrice();
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
      console.log(`Using deployer nonce: ${nonce}`);

      const deployer = new Deployer({
        deployWallet,
        verbose: true,
      });

      const zkSync = deployer.zkSyncContract(deployWallet);
      const requiredValueToInitializeBridge = await zkSync.l2TransactionBaseCost(
        gasPrice,
        DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
        REQUIRED_L2_GAS_PRICE_PER_PUBDATA
      );
      const calldata = getL2Calldata(l2WethBridgeAddress, l1WethTokenAddress, l2WethTokenImplAddress);

      const tx = await zkSync.requestL2Transaction(
        l2WethTokenProxyAddress,
        0,
        calldata,
        DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
        REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
        [],
        deployWallet.address,
        {
          gasPrice,
          value: requiredValueToInitializeBridge,
        }
      );

      console.log(`Transaction sent with hash ${tx.hash} and nonce ${tx.nonce}. Waiting for receipt...`);

      const receipt = await tx.wait();

      console.log(`L2 WETH token initialized, gasUsed: ${receipt.gasUsed.toString()}`);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
