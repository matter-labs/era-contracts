import { Command } from "commander";
import { ethers, Wallet } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { getTokens, web3Provider } from "../../l1-contracts/scripts/utils";
import { Deployer } from "../../l1-contracts/src.ts/deploy";

import { applyL1ToL2Alias, computeL2Create2Address, create2DeployFromL1, getNumberFromEnv } from "./utils";

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

function readBytecode(path: string, fileName: string) {
  return JSON.parse(fs.readFileSync(`${path}/${fileName}.sol/${fileName}.json`, { encoding: "utf-8" })).bytecode;
}

function readInterface(path: string, fileName: string) {
  const abi = JSON.parse(fs.readFileSync(`${path}/${fileName}.sol/${fileName}.json`, { encoding: "utf-8" })).abi;
  return new ethers.utils.Interface(abi);
}

const L2_WETH_INTERFACE = readInterface(l2BridgeArtifactsPath, "L2Weth");
const L2_WETH_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, "L2Weth");
const L2_WETH_PROXY_BYTECODE = readBytecode(openzeppelinTransparentProxyArtifactsPath, "TransparentUpgradeableProxy");
const tokens = getTokens(process.env.CHAIN_ETH_NETWORK || "localhost");
const l1WethToken = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;

async function main() {
  const program = new Command();

  program.version("0.1.0").name("deploy-l2-weth");

  program
    .option("--private-key <private-key>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .action(async (cmd) => {
      if (!l1WethToken) {
        // Makes no sense to deploy the Rollup WETH if there is no base Layer WETH provided
        console.log("Base Layer WETH address not provided so WETH deployment will be skipped.");
        return;
      }

      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/0"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, "gwei") : await provider.getGasPrice();
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
      console.log(`Using initial nonce: ${nonce}`);

      const deployer = new Deployer({
        deployWallet,
        verbose: true,
      });

      const zkSync = deployer.zkSyncContract(deployWallet);

      const priorityTxMaxGasLimit = getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT");
      const l1GovernorAddress = await zkSync.getGovernor();
      // Check whether governor is a smart contract on L1 to apply alias if needed.
      const l1GovernorCodeSize = ethers.utils.hexDataLength(await deployWallet.provider.getCode(l1GovernorAddress));
      const l2GovernorAddress = l1GovernorCodeSize == 0 ? l1GovernorAddress : applyL1ToL2Alias(l1GovernorAddress);

      const abiCoder = new ethers.utils.AbiCoder();

      const l2WethImplAddr = computeL2Create2Address(
        deployWallet,
        L2_WETH_IMPLEMENTATION_BYTECODE,
        "0x",
        ethers.constants.HashZero
      );

      const proxyInitializationParams = L2_WETH_INTERFACE.encodeFunctionData("initialize", ["Wrapped Ether", "WETH"]);
      const l2ERC20BridgeProxyConstructor = ethers.utils.arrayify(
        abiCoder.encode(["address", "address", "bytes"], [l2WethImplAddr, l2GovernorAddress, proxyInitializationParams])
      );
      const l2WethProxyAddr = computeL2Create2Address(
        deployWallet,
        L2_WETH_PROXY_BYTECODE,
        l2ERC20BridgeProxyConstructor,
        ethers.constants.HashZero
      );

      const tx = await create2DeployFromL1(
        deployWallet,
        L2_WETH_IMPLEMENTATION_BYTECODE,
        "0x",
        ethers.constants.HashZero,
        priorityTxMaxGasLimit
      );
      console.log(
        `WETH implementation transaction sent with hash ${tx.hash} and nonce ${tx.nonce}. Waiting for receipt...`
      );

      await tx.wait();

      const tx2 = await create2DeployFromL1(
        deployWallet,
        L2_WETH_PROXY_BYTECODE,
        l2ERC20BridgeProxyConstructor,
        ethers.constants.HashZero,
        priorityTxMaxGasLimit
      );
      console.log(`WETH proxy transaction sent with hash ${tx2.hash} and nonce ${tx2.nonce}. Waiting for receipt...`);

      await tx2.wait();

      console.log(`CONTRACTS_L2_WETH_TOKEN_IMPL_ADDR=${l2WethImplAddr}`);
      console.log(`CONTRACTS_L2_WETH_TOKEN_PROXY_ADDR=${l2WethProxyAddr}`);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
