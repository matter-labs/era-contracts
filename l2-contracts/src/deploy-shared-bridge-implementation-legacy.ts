import { Command } from "commander";
import { artifacts } from "hardhat";
import type { BigNumberish } from "ethers";
import { ethers, Wallet } from "ethers";
import { formatUnits, Interface, parseUnits, defaultAbiCoder } from "ethers/lib/utils";
import {
  computeL2Create2Address,
  provider,
  priorityTxMaxGasLimit,
  hashL2Bytecode,
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
} from "./utils";

import { ethTestConfig } from "./deploy-utils";

import { Deployer } from "../../l1-contracts/src.ts/deploy";
import { GAS_MULTIPLIER } from "../../l1-contracts/scripts/utils";
import { deployedAddressesFromEnv } from "../../l1-contracts/src.ts/deploy-utils";

import * as hre from "hardhat";
import { IZkSyncHyperchainFactory } from "../../l1-contracts/typechain/IZkSyncHyperchainFactory";

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = "0x0000000000000000000000000000000000008006";

const L2_SHARED_BRIDGE_IMPLEMENTATION_BYTECODE = hre.artifacts.readArtifactSync("L2SharedBridge").bytecode;

async function create2DeployFromL1(
  chainId: ethers.BigNumberish,
  wallet: ethers.Wallet,
  bytecode: ethers.BytesLike,
  constructor: ethers.BytesLike,
  create2Salt: ethers.BytesLike,
  l2GasLimit: ethers.BigNumberish,
  gasPrice?: ethers.BigNumberish,
  extraFactoryDeps?: ethers.BytesLike[]
) {
  const hyperchainAddress = deployedAddressesFromEnv().StateTransition.DiamondProxy;
  const hyperchain = IZkSyncHyperchainFactory.connect(hyperchainAddress, wallet);

  const deployerSystemContracts = new Interface(artifacts.readArtifactSync("IContractDeployer").abi);
  const bytecodeHash = hashL2Bytecode(bytecode);
  const calldata = deployerSystemContracts.encodeFunctionData("create2", [create2Salt, bytecodeHash, constructor]);
  gasPrice ??= await wallet.provider.getGasPrice();
  const expectedCost = await hyperchain.l2TransactionBaseCost(gasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

  const factoryDeps = extraFactoryDeps ? [bytecode, ...extraFactoryDeps] : [bytecode];
  return await hyperchain.requestL2Transaction(
    DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
    0,
    calldata,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    factoryDeps,
    wallet.address,
    { value: expectedCost.mul(5), gasPrice }
  );
}

export async function publishBytecodeFromL1(
  wallet: ethers.Wallet,
  factoryDeps: ethers.BytesLike[],
  gasPrice?: ethers.BigNumberish
) {
  const hyperchainAddress = deployedAddressesFromEnv().StateTransition.DiamondProxy;
  const hyperchain = IZkSyncHyperchainFactory.connect(hyperchainAddress, wallet);

  const requiredValueToPublishBytecodes = await hyperchain.l2TransactionBaseCost(
    gasPrice,
    priorityTxMaxGasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );

  const nonce = await wallet.getTransactionCount();
  const tx1 = await hyperchain.requestL2Transaction(
    ethers.constants.AddressZero,
    0,
    "0x",
    priorityTxMaxGasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    factoryDeps,
    wallet.address,
    { gasPrice, nonce, value: requiredValueToPublishBytecodes }
  );
  await tx1.wait();
}

export async function publishL2SharedBridgeDependencyBytecodesOnL2(
  deployer: Deployer,
  chainId: string,
  gasPrice: BigNumberish
) {
  /// ####################################################################################################################

  if (deployer.verbose) {
    console.log("Providing necessary L2 bytecodes");
  }

  const L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE = hre.artifacts.readArtifactSync("UpgradeableBeacon").bytecode;
  const L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE = hre.artifacts.readArtifactSync("L2StandardERC20").bytecode;

  await publishBytecodeFromL1(
    deployer.deployWallet,
    [L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE, L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE],
    gasPrice
  );

  if (deployer.verbose) {
    console.log("Bytecodes published on L2");
  }
}

export async function deploySharedBridgeImplOnL2ThroughL1(deployer: Deployer, chainId: string, gasPrice: BigNumberish) {
  if (deployer.verbose) {
    console.log("Deploying L2SharedBridge Implementation");
  }

  if (!L2_SHARED_BRIDGE_IMPLEMENTATION_BYTECODE) {
    throw new Error("L2_SHARED_BRIDGE_IMPLEMENTATION_BYTECODE not found");
  }
  if (deployer.verbose) {
    console.log("L2_SHARED_BRIDGE_IMPLEMENTATION_BYTECODE loaded");

    console.log("Computing L2SharedBridge Implementation Address");
  }
  const l2SharedBridgeImplAddress = computeL2Create2Address(
    deployer.deployWallet,
    L2_SHARED_BRIDGE_IMPLEMENTATION_BYTECODE,
    defaultAbiCoder.encode(["uint256"], [deployer.chainId]),
    ethers.constants.HashZero
  );
  deployer.addresses.Bridges.L2SharedBridgeImplementation = l2SharedBridgeImplAddress;
  if (deployer.verbose) {
    console.log(`L2SharedBridge Implementation Address: ${l2SharedBridgeImplAddress}`);

    console.log("Deploying L2SharedBridge Implementation");
  }

  /// L2StandardTokenProxy bytecode. We need this bytecode to be accessible on the L2, it is enough to add to factoryDeps
  const L2_STANDARD_TOKEN_PROXY_BYTECODE = hre.artifacts.readArtifactSync("BeaconProxy").bytecode;

  // TODO: request from API how many L2 gas needs for the transaction.
  const tx2 = await create2DeployFromL1(
    chainId,
    deployer.deployWallet,
    L2_SHARED_BRIDGE_IMPLEMENTATION_BYTECODE,
    defaultAbiCoder.encode(["uint256"], [deployer.chainId]),
    ethers.constants.HashZero,
    priorityTxMaxGasLimit,
    gasPrice,
    [L2_STANDARD_TOKEN_PROXY_BYTECODE]
  );

  await tx2.wait();
  if (deployer.verbose) {
    console.log("Deployed L2SharedBridge Implementation");
    console.log(`CONTRACTS_L2_SHARED_BRIDGE_IMPL_ADDR=${l2SharedBridgeImplAddress}`);
  }
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("deploy-shared-bridge-on-l2-through-l1");

  program
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--erc20-bridge <erc20-bridge>")
    .action(async (cmd) => {
      const chainId: string = cmd.chainId ? cmd.chainId : process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID;
      const deployWallet = cmd.privateKey
        ? new Wallet(cmd.privateKey, provider)
        : Wallet.fromMnemonic(
            process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
            "m/44'/60'/0'/0/1"
          ).connect(provider);
      console.log(`Using deployer wallet: ${deployWallet.address}`);

      const deployer = new Deployer({
        deployWallet,
        ownerAddress: deployWallet.address,
        verbose: true,
      });

      const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployer.deployWallet.getTransactionCount();
      console.log(`Using nonce: ${nonce}`);

      const gasPrice = cmd.gasPrice
        ? parseUnits(cmd.gasPrice, "gwei")
        : (await provider.getGasPrice()).mul(GAS_MULTIPLIER);
      console.log(`Using gas price: ${formatUnits(gasPrice, "gwei")} gwei`);
      await publishL2SharedBridgeDependencyBytecodesOnL2(deployer, chainId, gasPrice);
      await deploySharedBridgeImplOnL2ThroughL1(deployer, chainId, gasPrice);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
