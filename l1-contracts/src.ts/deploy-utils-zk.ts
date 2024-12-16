import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { Deployer as ZkDeployer } from "@matterlabs/hardhat-zksync-deploy";
// import "@matterlabs/hardhat-zksync-ethers";
import { ethers } from "ethers";
import * as path from "path";
import { IL2ContractDeployerFactory } from "../typechain/IL2ContractDeployerFactory";
import type { Wallet as ZkWallet } from "zksync-ethers";
import { utils as zkUtils, ContractFactory } from "zksync-ethers";
// import { encode } from "querystring";
// import { web3Provider, web3Url } from "../scripts/utils";
import { ethersWalletToZkWallet, readBytecode, readContract, readInterface } from "./utils";

export const BUILT_IN_ZKSYNC_CREATE2_FACTORY = "0x0000000000000000000000000000000000010000";

const contractsHome = process.env.ZKSYNC_HOME ? path.join(process.env.ZKSYNC_HOME as string, "contracts/") : "../";
const contractArtifactsPath = path.join(contractsHome, "l1-contracts/artifacts-zk/");
const openzeppelinBeaconProxyArtifactsPath = path.join(
  contractArtifactsPath,
  "@openzeppelin/contracts-v4/proxy/beacon"
);
const L2_SHARED_BRIDGE_PATH = contractArtifactsPath + "contracts/bridge";
export const L2_STANDARD_ERC20_PROXY_FACTORY = readContract(openzeppelinBeaconProxyArtifactsPath, "UpgradeableBeacon");
export const L2_STANDARD_ERC20_IMPLEMENTATION = readContract(L2_SHARED_BRIDGE_PATH, "BridgedStandardERC20");
export const L2_STANDARD_TOKEN_PROXY = readContract(openzeppelinBeaconProxyArtifactsPath, "BeaconProxy");

export const L2_SHARED_BRIDGE_IMPLEMENTATION = readContract(L2_SHARED_BRIDGE_PATH, "L2SharedBridgeLegacy");
export const L2_SHARED_BRIDGE_PROXY = readContract(
  contractArtifactsPath + "@openzeppelin/contracts-v4/proxy/transparent",
  "TransparentUpgradeableProxy"
);

export async function deployViaCreate2(
  deployWallet: ZkWallet,
  contractName: string,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  args: any[],
  create2Salt: string,
  ethTxOptions: ethers.providers.TransactionRequest,
  verbose: boolean = true
): Promise<[string, string]> {
  return await deployBytecodeViaCreate2(deployWallet, contractName, create2Salt, ethTxOptions, args, verbose);
}

export async function deployBytecodeViaCreate2(
  deployWallet: ZkWallet,
  contractName: string,
  create2Salt: string,
  ethTxOptions: ethers.providers.TransactionRequest,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  args: any[],
  verbose: boolean = true
): Promise<[string, string]> {
  // [address, txHash]

  const log = (msg: string) => {
    if (verbose) {
      console.log(msg);
    }
  };
  log(`Deploying ${contractName}`);

  // @ts-ignore
  const zkDeployer = new ZkDeployer(hardhat, deployWallet);
  const artifact = await zkDeployer.loadArtifact(contractName);
  const factoryDeps = await zkDeployer.extractFactoryDeps(artifact);

  const bytecodeHash = zkUtils.hashBytecode(artifact.bytecode);
  const iface = new ethers.utils.Interface(artifact.abi);
  const encodedArgs = iface.encodeDeploy(args);

  // The CREATE2Factory has the same interface as the contract deployer
  const create2Factory = IL2ContractDeployerFactory.connect(BUILT_IN_ZKSYNC_CREATE2_FACTORY, deployWallet);
  const expectedAddress = zkUtils.create2Address(create2Factory.address, bytecodeHash, create2Salt, encodedArgs);

  const deployedBytecodeBefore = await deployWallet.provider.getCode(expectedAddress);
  if (ethers.utils.hexDataLength(deployedBytecodeBefore) > 0) {
    log(`Contract ${contractName} already deployed`);
    return [expectedAddress, ethers.constants.HashZero];
  }

  const encodedTx = create2Factory.interface.encodeFunctionData("create2", [create2Salt, bytecodeHash, encodedArgs]);

  const tx = await deployWallet.sendTransaction({
    data: encodedTx,
    to: create2Factory.address,
    ...ethTxOptions,
    customData: {
      factoryDeps: [artifact.bytecode, ...factoryDeps],
    },
  });
  const receipt = await tx.wait();

  const gasUsed = receipt.gasUsed;
  log(`${contractName} deployed, gasUsed: ${gasUsed.toString()}`);

  const deployedBytecodeAfter = await deployWallet.provider.getCode(expectedAddress);
  if (ethers.utils.hexDataLength(deployedBytecodeAfter) == 0) {
    throw new Error(`Failed to deploy ${contractName} bytecode via create2 factory`);
  }

  return [expectedAddress, tx.hash];
}

export async function deployBytecodeViaCreate2OnPath(
  deployWallet: ZkWallet,
  contractName: string,
  contractPath: string,
  create2Salt: string,
  ethTxOptions: ethers.providers.TransactionRequest,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  args: any[],
  factoryDeps: string[] = [],
  verbose: boolean = true
): Promise<[string, string]> {
  // [address, txHash]

  const log = (msg: string) => {
    if (verbose) {
      console.log(msg);
    }
  };

  // @ts-ignore
  // const zkDeployer = new ZkDeployer(hardhat, deployWallet);
  const bytecode = readBytecode(contractPath, contractName);

  const bytecodeHash = zkUtils.hashBytecode(bytecode);
  const iface = readInterface(contractPath, contractName);
  const encodedArgs = iface.encodeDeploy(args);

  // The CREATE2Factory has the same interface as the contract deployer
  const create2Factory = IL2ContractDeployerFactory.connect(BUILT_IN_ZKSYNC_CREATE2_FACTORY, deployWallet);
  const expectedAddress = zkUtils.create2Address(create2Factory.address, bytecodeHash, create2Salt, encodedArgs);

  const deployedBytecodeBefore = await deployWallet.provider.getCode(expectedAddress);
  if (ethers.utils.hexDataLength(deployedBytecodeBefore) > 0) {
    log(`Contract ${contractName} already deployed`);
    return [expectedAddress, ethers.constants.HashZero];
  }

  const encodedTx = create2Factory.interface.encodeFunctionData("create2", [create2Salt, bytecodeHash, encodedArgs]);

  const tx = await deployWallet.sendTransaction({
    data: encodedTx,
    to: create2Factory.address,
    ...ethTxOptions,
    customData: {
      factoryDeps: [bytecode, ...factoryDeps],
    },
  });
  const receipt = await tx.wait();

  const gasUsed = receipt.gasUsed;
  log(`${contractName} deployed, gasUsed: ${gasUsed.toString()}`);

  const deployedBytecodeAfter = await deployWallet.provider.getCode(expectedAddress);
  if (ethers.utils.hexDataLength(deployedBytecodeAfter) == 0) {
    throw new Error(`Failed to deploy ${contractName} bytecode via create2 factory`);
  }

  return [expectedAddress, tx.hash];
}
export async function deployContractWithArgs(
  wallet: ethers.Wallet,
  contractName: string,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  args: any[],
  ethTxOptions: ethers.providers.TransactionRequest
) {
  const artifact = await hardhat.artifacts.readArtifact(contractName);
  const zkWallet = ethersWalletToZkWallet(wallet);
  const factory = new ContractFactory(artifact.abi, artifact.bytecode, zkWallet);

  return await factory.deploy(...args, ethTxOptions);
}
