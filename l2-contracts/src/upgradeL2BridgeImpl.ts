import "@nomiclabs/hardhat-ethers";
import { Command } from "commander";
import { BigNumber, Wallet, ethers } from "ethers";
import * as fs from "fs";
import * as hre from "hardhat";
import * as path from "path";
import { Provider } from "zksync-web3";
import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT } from "zksync-web3/build/src/utils";
import { getAddressFromEnv, getNumberFromEnv, web3Provider } from "../../l1-contracts/scripts/utils";
import { Deployer } from "../../l1-contracts/src.ts/deploy";
import { awaitPriorityOps, computeL2Create2Address, create2DeployFromL1, getL1TxInfo } from "./utils";

export function getContractBytecode(contractName: string) {
  return hre.artifacts.readArtifactSync(contractName).bytecode;
}

type SupportedContracts = "L2ERC20Bridge" | "L2StandardERC20" | "L2WethBridge" | "L2Weth";
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function checkSupportedContract(contract: any): contract is SupportedContracts {
  if (!["L2ERC20Bridge", "L2StandardERC20", "L2WethBridge", "L2Weth"].includes(contract)) {
    throw new Error(`Unsupported contract: ${contract}`);
  }

  return true;
}

const priorityTxMaxGasLimit = BigNumber.from(getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT"));
const l2Erc20BridgeProxyAddress = getAddressFromEnv("CONTRACTS_L2_ERC20_BRIDGE_ADDR");
const EIP1967_IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

async function getERC20BeaconAddress() {
  const provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
  const bridge = (await provider.getDefaultBridgeAddresses()).erc20L2;
  const artifact = await hre.artifacts.readArtifact("L2ERC20Bridge");
  const contract = new ethers.Contract(bridge, artifact.abi, provider);

  return await contract.l2TokenBeacon();
}

async function getWETHAddress() {
  const provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
  const wethToken = process.env.CONTRACTS_L2_WETH_TOKEN_PROXY_ADDR;
  return ethers.utils.hexStripZeros(await provider.getStorageAt(wethToken, EIP1967_IMPLEMENTATION_SLOT));
}

async function getTransparentProxyUpgradeCalldata(target: string) {
  const proxyArtifact = await hre.artifacts.readArtifact("TransparentUpgradeableProxy");
  const proxyInterface = new ethers.utils.Interface(proxyArtifact.abi);

  return proxyInterface.encodeFunctionData("upgradeTo", [target]);
}

async function getBeaconProxyUpgradeCalldata(target: string) {
  const proxyArtifact = await hre.artifacts.readArtifact("UpgradeableBeacon");
  const proxyInterface = new ethers.utils.Interface(proxyArtifact.abi);

  return proxyInterface.encodeFunctionData("upgradeTo", [target]);
}

async function getTransparentProxyUpgradeTxInfo(
  deployer: Deployer,
  target: string,
  proxyAddress: string,
  refundRecipient: string,
  gasPrice: BigNumber
) {
  const l2Calldata = await getTransparentProxyUpgradeCalldata(target);
  return await getL1TxInfo(deployer, proxyAddress, l2Calldata, refundRecipient, gasPrice);
}

async function getTokenBeaconUpgradeTxInfo(
  deployer: Deployer,
  target: string,
  refundRecipient: string,
  gasPrice: BigNumber,
  proxy: string
) {
  const l2Calldata = await getBeaconProxyUpgradeCalldata(target);

  return await getL1TxInfo(deployer, proxy, l2Calldata, refundRecipient, gasPrice, priorityTxMaxGasLimit, provider);
}

async function getTxInfo(
  deployer: Deployer,
  target: string,
  refundRecipient: string,
  gasPrice: BigNumber,
  contract: SupportedContracts,
  l2ProxyAddress?: string
) {
  if (contract === "L2ERC20Bridge") {
    return getTransparentProxyUpgradeTxInfo(deployer, target, l2Erc20BridgeProxyAddress, refundRecipient, gasPrice);
  } else if (contract == "L2Weth") {
    throw new Error(
      "The latest L2Weth implementation requires L2WethBridge to be deployed in order to be correctly initialized, which is not the case on the majority of networks. Remove this error once the bridge is deployed."
    );
  } else if (contract == "L2StandardERC20") {
    if (!l2ProxyAddress) {
      console.log("Explicit beacon address is not supplied, requesting the one from L2 node");
      l2ProxyAddress = await getERC20BeaconAddress();
    }
    console.log(`Using beacon address: ${l2ProxyAddress}`);

    return getTokenBeaconUpgradeTxInfo(deployer, target, refundRecipient, gasPrice, l2ProxyAddress);
  } else {
    throw new Error(`Unsupported contract: ${contract}`);
  }
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-l2-bridge-impl");

  program
    .command("deploy-target")
    .option("--contract <contract>")
    .option("--private-key <private-key>")
    .option("--gas-price <gas-price>")
    .option("--create2-salt <create2-salt>")
    .option("--no-l2-double-check")
    .action(async (cmd) => {
      // We deploy the target contract through L1 to ensure security
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      const deployer = new Deployer({ deployWallet });
      const gasPrice = cmd.gasPrice
        ? ethers.utils.parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(3).div(2);
      const salt = cmd.create2Salt ? cmd.create2Salt : ethers.utils.hexlify(ethers.constants.HashZero);
      checkSupportedContract(cmd.contract);

      console.log(`Using deployer wallet: ${deployWallet.address}`);
      console.log("Gas price: ", ethers.utils.formatUnits(gasPrice, "gwei"));
      console.log("Salt: ", salt);

      const bridgeImplBytecode = getContractBytecode(cmd.contract);
      const l2ERC20BridgeImplAddr = computeL2Create2Address(deployWallet, bridgeImplBytecode, "0x", salt);
      console.log("Bridge implemenation address: ", l2ERC20BridgeImplAddr);

      if (cmd.l2DoubleCheck !== false) {
        // If the bytecode has already been deployed there is no need to deploy it again.
        const zksProvider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
        const deployedBytecode = await zksProvider.getCode(l2ERC20BridgeImplAddr);
        if (deployedBytecode === bridgeImplBytecode) {
          console.log("The bytecode has been already deployed!");
          console.log("Address:", l2ERC20BridgeImplAddr);
          return;
        } else if (ethers.utils.arrayify(deployedBytecode).length > 0) {
          console.log("CREATE2 DERIVATION: A different bytecode has been deployed on that address");
          process.exit(1);
        } else {
          console.log("The contract has not been deployed yet. Proceeding with deployment");
        }
      }

      const tx = await create2DeployFromL1(
        deployWallet,
        bridgeImplBytecode,
        "0x",
        salt,
        priorityTxMaxGasLimit,
        gasPrice
      );
      console.log("L1 tx hash: ", tx.hash);

      const receipt = await tx.wait();
      if (receipt.status !== 1) {
        console.error("L1 tx failed");
        process.exit(1);
      }

      // Double checking that the deployment has been successful on L2.
      // Note that it requires working L2 node.
      if (cmd.l2DoubleCheck !== false) {
        console.log("Waiting for the L2 transaction to be committed...");
        const zksProvider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
        await awaitPriorityOps(zksProvider, receipt, deployer.zkSyncContract(deployWallet).interface);

        // Double checking that the bridge implementation has been deployed
        const deployedBytecode = await zksProvider.getCode(l2ERC20BridgeImplAddr);
        if (deployedBytecode != bridgeImplBytecode) {
          console.error("Bridge implementation has not been deployed");
          process.exit(1);
        } else {
          console.log("Transaction has been successfully committed");
        }
      }

      console.log("\n");
      console.log("Bridge implementation has been successfuly deployed!");
      console.log("Address:", l2ERC20BridgeImplAddr);
    });

  program
    .command("prepare-l1-tx-info")
    .option("--contract <contract>")
    .option("--target-address <target-address>")
    .option("--l2-proxy-address <l2-proxy-address>")
    .option("--gas-price <gas-price>")
    .option("--deployer-private-key <deployer-private-key>")
    .option("--refund-recipient <refund-recipient>")
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
      const target = cmd.targetAddress as string;
      if (!target) {
        throw new Error("L2 target address is not provided");
      }
      checkSupportedContract(cmd.contract);

      const refundRecipient = cmd.refundRecipient ? cmd.refundRecipient : deployWallet.address;
      console.log("Gas price: ", ethers.utils.formatUnits(gasPrice, "gwei"));
      console.log("Target address: ", target);
      console.log("Refund recipient: ", refundRecipient);
      const txInfo = await getTxInfo(deployer, target, refundRecipient, gasPrice, cmd.contract, cmd.l2ProxyAddress);

      console.log(JSON.stringify(txInfo, null, 4));
      console.log("IMPORTANT: gasPrice that you provide in the transaction should <= to the one provided above.");
    });

  program
    .command("instant-upgrade")
    .option("--contract <contract>")
    .option("--target-address <target-address>")
    .option("--l2-proxy-address <l2-proxy-address>")
    .option("--gas-price <gas-price>")
    .option("--governor-private-key <governor-private-key>")
    .option("--refund-recipient <refund-recipient>")
    .option("--no-l2-double-check")
    .action(async (cmd) => {
      const gasPrice = cmd.gasPrice
        ? ethers.utils.parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(3).div(2);
      const deployWallet = cmd.governorPrivateKey
        ? new Wallet(cmd.governorPrivateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      const deployer = new Deployer({ deployWallet });
      const target = cmd.targetAddress as string;
      if (!target) {
        throw new Error("L2 target address is not provided");
      }
      checkSupportedContract(cmd.contract);

      const refundRecipient = cmd.refundRecipient ? cmd.refundRecipient : deployWallet.address;
      console.log(`Using deployer wallet: ${deployWallet.address}`);
      console.log("Gas price: ", ethers.utils.formatUnits(gasPrice, "gwei"));
      console.log("Target address: ", target);
      console.log("Refund recipient: ", refundRecipient);

      const txInfo = await getTxInfo(deployer, target, refundRecipient, gasPrice, cmd.contract, cmd.l2ProxyAddress);
      const tx = await deployWallet.sendTransaction(txInfo);
      console.log("L1 tx hash: ", tx.hash);

      const receipt = await tx.wait();
      if (receipt.status !== 1) {
        console.error("L1 tx failed");
        process.exit(1);
      }

      // Double checking that the upgrade has been successful on L2.
      // Note that it requires working L2 node.
      if (cmd.l2DoubleCheck !== false) {
        const zksProvider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
        await awaitPriorityOps(zksProvider, receipt, deployer.zkSyncContract(deployWallet).interface);

        console.log("The L2 transaction has been successfully committed");
      }
    });

  program.command("get-l2-erc20-beacon-address").action(async () => {
    console.log(`L2 ERC20 beacon address: ${await getERC20BeaconAddress()}`);
  });

  program.command("get-weth-token-implementation").action(async () => {
    console.log(`WETH token implementation address: ${await getWETHAddress()}`);
  });

  program
    .command("get-base-cost-for-max-op")
    .option("--gas-price <gas-price>")
    .action(async (cmd) => {
      if (!cmd.gasPrice) {
        throw new Error("Gas price is not provided");
      }

      const gasPrice = ethers.utils.parseUnits(cmd.gasPrice, "gwei");

      const deployer = new Deployer({ deployWallet: Wallet.createRandom().connect(provider) });
      const zksync = deployer.zkSyncContract(ethers.Wallet.createRandom().connect(provider));

      const neededValue = await zksync.l2TransactionBaseCost(
        gasPrice,
        priorityTxMaxGasLimit,
        REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT
      );

      console.log(`Base cost for priority tx with max ergs: ${ethers.utils.formatEther(neededValue)} ETH`);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
