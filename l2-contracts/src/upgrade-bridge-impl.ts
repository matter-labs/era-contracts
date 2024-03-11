// hardhat import should be the first import in the file
import * as hre from "hardhat";

import "@nomiclabs/hardhat-ethers";
import { Command } from "commander";
import { BigNumber, Wallet, ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { Provider } from "zksync-web3";
import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT } from "zksync-web3/build/src/utils";
import { web3Provider } from "../../l1-contracts/scripts/utils";
import { getAddressFromEnv, getNumberFromEnv } from "../../l1-contracts/src.ts/utils";
import { Deployer } from "../../l1-contracts/src.ts/deploy";
import { awaitPriorityOps, computeL2Create2Address, create2DeployFromL1, getL1TxInfo } from "./utils";

const SupportedL2Contracts = ["L2SharedBridge", "L2StandardERC20", "L2WrappedBaseToken"] as const;

// For L1 contracts we can not read bytecodes, but we can still produce the upgrade calldata
const SupportedL1Contracts = ["L1ERC20Bridge"] as const;

const SupportedContracts = [...SupportedL1Contracts, ...SupportedL2Contracts] as const;

type SupportedL2Contract = (typeof SupportedL2Contracts)[number];
type SupportedContract = (typeof SupportedContracts)[number];

interface UpgradeInfo {
  contract: SupportedContract;
  target: string;
  l2ProxyAddress?: string;
}

export function getContractBytecode(contractName: SupportedL2Contract) {
  return hre.artifacts.readArtifactSync(contractName).bytecode;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function checkSupportedL2Contract(contract: any): contract is SupportedL2Contract {
  if (!SupportedL2Contracts.includes(contract)) {
    throw new Error(`Unsupported contract: ${contract}`);
  }

  return true;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function checkSupportedContract(contract: any): contract is SupportedContract {
  if (!SupportedContracts.includes(contract)) {
    throw new Error(`Unsupported contract: ${contract}`);
  }

  return true;
}

function validateUpgradeInfo(info: UpgradeInfo) {
  if (!info.target) {
    throw new Error("L2 target address is not provided");
  }
  checkSupportedContract(info.contract);
}

const priorityTxMaxGasLimit = BigNumber.from(getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT"));
const l2SharedBridgeProxyAddress = getAddressFromEnv("CONTRACTS_L2_SHARED_BRIDGE_ADDR");
const l1Erc20BridgeProxyAddress = getAddressFromEnv("CONTRACTS_L1_SHARED_BRIDGE_PROXY_ADDR");
const EIP1967_IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

async function getERC20BeaconAddress() {
  const provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
  const bridge = (await provider.getDefaultBridgeAddresses()).erc20L2;
  const artifact = await hre.artifacts.readArtifact("L2SharedBridge");
  const contract = new ethers.Contract(bridge, artifact.abi, provider);

  return await contract.l2TokenBeacon();
}

async function getWETHAddress() {
  const provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
  const wethToken = process.env.CONTRACTS_L2_WETH_TOKEN_PROXY_ADDR;
  return ethers.utils.hexStripZeros(await provider.getStorageAt(wethToken, EIP1967_IMPLEMENTATION_SLOT));
}

async function getTransparentProxyUpgradeCalldata(target: string) {
  const proxyArtifact = await hre.artifacts.readArtifact("ITransparentUpgradeableProxy");
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
  return await getL1TxInfo(
    deployer,
    proxyAddress,
    l2Calldata,
    refundRecipient,
    gasPrice,
    priorityTxMaxGasLimit,
    provider
  );
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

async function getL1BridgeUpgradeTxInfo(proxyTarget: string) {
  return {
    target: l1Erc20BridgeProxyAddress,
    value: 0,
    data: await getTransparentProxyUpgradeCalldata(proxyTarget),
  };
}

async function getTxInfo(
  deployer: Deployer,
  target: string,
  refundRecipient: string,
  gasPrice: BigNumber,
  contract: SupportedContract,
  l2ProxyAddress?: string
) {
  if (contract === "L2SharedBridge") {
    return getTransparentProxyUpgradeTxInfo(deployer, target, l2SharedBridgeProxyAddress, refundRecipient, gasPrice);
  } else if (contract == "L2WrappedBaseToken") {
    throw new Error(
      "The latest L2WrappedBaseToken implementation requires L2SharedBridge to be deployed in order to be correctly initialized, which is not the case on the majority of networks. Remove this error once the bridge is deployed."
    );
  } else if (contract == "L2StandardERC20") {
    if (!l2ProxyAddress) {
      console.log("Explicit beacon address is not supplied, requesting the one from L2 node");
      l2ProxyAddress = await getERC20BeaconAddress();
    }
    console.log(`Using beacon address: ${l2ProxyAddress}`);

    return getTokenBeaconUpgradeTxInfo(deployer, target, refundRecipient, gasPrice, l2ProxyAddress);
  } else if (contract == "L1ERC20Bridge") {
    return await getL1BridgeUpgradeTxInfo(target);
  } else {
    throw new Error(`Unsupported contract: ${contract}`);
  }
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-l2-bridge-impl");

  program
    .command("deploy-l2-target")
    .option("--contract <contract>")
    .option("--private-key <private-key>")
    .option("--gas-price <gas-price>")
    .option("--create2-salt <create2-salt>")
    .option("--no-l2-double-check")
    .action(async (cmd) => {
      // We deploy the target contract through L1 to ensure security
      const chainId: string = cmd.chainId ? cmd.chainId : process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID;
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
      checkSupportedL2Contract(cmd.contract);

      console.log(`Using deployer wallet: ${deployWallet.address}`);
      console.log("Gas price: ", ethers.utils.formatUnits(gasPrice, "gwei"));
      console.log("Salt: ", salt);

      const bridgeImplBytecode = getContractBytecode(cmd.contract);
      const l2SharedBridgeImplAddr = computeL2Create2Address(deployWallet, bridgeImplBytecode, "0x", salt);
      console.log("Bridge implementation address: ", l2SharedBridgeImplAddr);

      if (cmd.l2DoubleCheck !== false) {
        // If the bytecode has already been deployed there is no need to deploy it again.
        const zksProvider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
        const deployedBytecode = await zksProvider.getCode(l2SharedBridgeImplAddr);
        if (deployedBytecode === bridgeImplBytecode) {
          console.log("The bytecode has been already deployed!");
          console.log("Address:", l2SharedBridgeImplAddr);
          return;
        } else if (ethers.utils.arrayify(deployedBytecode).length > 0) {
          console.log("CREATE2 DERIVATION: A different bytecode has been deployed on that address");
          process.exit(1);
        } else {
          console.log("The contract has not been deployed yet. Proceeding with deployment");
        }
      }

      const tx = await create2DeployFromL1(
        chainId,
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
        await awaitPriorityOps(zksProvider, receipt, deployer.bridgehubContract(deployWallet).interface);

        // Double checking that the bridge implementation has been deployed
        const deployedBytecode = await zksProvider.getCode(l2SharedBridgeImplAddr);
        if (deployedBytecode != bridgeImplBytecode) {
          console.error("Bridge implementation has not been deployed");
          process.exit(1);
        } else {
          console.log("Transaction has been successfully committed");
        }
      }

      console.log("\n");
      console.log("Bridge implementation has been successfully deployed!");
      console.log("Address:", l2SharedBridgeImplAddr);
    });

  program
    .command("prepare-l1-tx-info")
    .option("--upgrades-info <upgrades-info>")
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
      const refundRecipient = cmd.refundRecipient ? cmd.refundRecipient : deployWallet.address;
      console.log("Gas price: ", ethers.utils.formatUnits(gasPrice, "gwei"));
      console.log(
        "IMPORTANT: gasPrice that you provide in the transaction should be <= to the one provided to this tool."
      );

      console.log("Refund recipient: ", refundRecipient);

      const upgradeInfos = JSON.parse(cmd.upgradesInfo) as UpgradeInfo[];
      upgradeInfos.forEach(validateUpgradeInfo);

      const governanceCalls = [];
      for (const info of upgradeInfos) {
        console.log("Generating upgrade transaction for contract: ", info.contract);
        console.log("Target address: ", info.target);
        const txInfo = await getTxInfo(
          deployer,
          info.target,
          refundRecipient,
          gasPrice,
          info.contract,
          info.l2ProxyAddress
        );

        console.log(JSON.stringify(txInfo, null, 4) + "\n");

        governanceCalls.push(txInfo);
      }

      const operation = {
        calls: governanceCalls,
        predecessor: ethers.constants.HashZero,
        salt: ethers.constants.HashZero,
      };

      console.log("Combined list of governance calls: ");
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
      const zksync = deployer.bridgehubContract(ethers.Wallet.createRandom().connect(provider));
      const chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID;
      const neededValue = await zksync.l2TransactionBaseCost(
        chainId,
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
