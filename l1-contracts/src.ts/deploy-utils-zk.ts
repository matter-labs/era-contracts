import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { Deployer as ZkDeployer } from "@matterlabs/hardhat-zksync-deploy";
// import "@matterlabs/hardhat-zksync-ethers";
import { ethers } from "ethers";
import { IL2ContractDeployerFactory } from "../typechain/IL2ContractDeployerFactory";
import { utils as zkUtils, ContractFactory, Wallet as ZkWallet, Provider } from "zksync-ethers";
import { encode } from "querystring";
import { web3Provider, web3Url } from "../scripts/utils";
import { ethersWalletToZkWallet } from "./utils";

export const BUILT_IN_ZKSYNC_CREATE2_FACTORY = "0x0000000000000000000000000000000000010000";

export async function deployViaCreate2(
  deployWallet: ethers.Wallet,
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
  deployWallet: ethers.Wallet,
  contractName: string,
  create2Salt: string,
  ethTxOptions: ethers.providers.TransactionRequest,
  args: any[],
  verbose: boolean = true
): Promise<[string, string]> {
  // [address, txHash]

  const zksyncWallet = new ZkWallet(deployWallet.privateKey, new Provider(web3Url()));

  const log = (msg: string) => {
    if (verbose) {
      console.log(msg);
    }
  };
  log(`Deploying ${contractName}`);

  // @ts-ignore
  const zkDeployer = ZkDeployer.fromEthWallet(hardhat, deployWallet);
  const artifact = await zkDeployer.loadArtifact(contractName);
  const factoryDeps = await zkDeployer.extractFactoryDeps(artifact);

  const bytecodeHash = zkUtils.hashBytecode(artifact.bytecode);
  const iface = new ethers.utils.Interface(artifact.abi);
  const encodedArgs = iface.encodeDeploy(args);

  // The CREATE2Factory has the same interface as the contract deployer
  const create2Factory = IL2ContractDeployerFactory.connect(BUILT_IN_ZKSYNC_CREATE2_FACTORY, zksyncWallet);
  const expectedAddress = zkUtils.create2Address(create2Factory.address, bytecodeHash, create2Salt, encodedArgs);

  const deployedBytecodeBefore = await zksyncWallet.provider.getCode(expectedAddress);
  if (ethers.utils.hexDataLength(deployedBytecodeBefore) > 0) {
    log(`Contract ${contractName} already deployed`);
    return [expectedAddress, ethers.constants.HashZero];
  }

  const encodedTx = create2Factory.interface.encodeFunctionData("create2", [create2Salt, bytecodeHash, encodedArgs]);

  const tx = await zksyncWallet.sendTransaction({
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

  const deployedBytecodeAfter = await zksyncWallet.provider.getCode(expectedAddress);
  if (ethers.utils.hexDataLength(deployedBytecodeAfter) == 0) {
    throw new Error(`Failed to deploy ${contractName} bytecode via create2 factory`);
  }

  return [expectedAddress, tx.hash];
}

export async function deployContractWithArgs(
  wallet: ethers.Wallet,
  contractName: string,
  args: any[],
  ethTxOptions: ethers.providers.TransactionRequest
) {
  const artifact = await hardhat.artifacts.readArtifact(contractName);
  const zkWallet = ethersWalletToZkWallet(wallet);
  const factory = new ContractFactory(artifact.abi, artifact.bytecode, zkWallet);

  return await factory.deploy(...args, ethTxOptions);
}
