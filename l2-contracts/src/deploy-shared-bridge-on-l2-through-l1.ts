import { Command } from "commander";
import type { BigNumberish } from "ethers";
import { Wallet, ethers } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { provider, publishBytecodeFromL1, priorityTxMaxGasLimit } from "./utils";

import { ethTestConfig } from "./deploy-utils";

import { Deployer } from "../../l1-contracts/src.ts/deploy";
import { GAS_MULTIPLIER } from "../../l1-contracts/scripts/utils";
import * as hre from "hardhat";
import {
  ADDRESS_ONE,
  L2_ASSET_ROUTER_ADDRESS,
  L2_BRIDGEHUB_ADDRESS,
  L2_MESSAGE_ROOT_ADDRESS,
  L2_NATIVE_TOKEN_VAULT_ADDRESS,
} from "../../l1-contracts/src.ts/utils";

import { L2NativeTokenVaultFactory } from "../typechain";
import { BridgehubFactory } from "../../l1-contracts/typechain";

export const L2_SHARED_BRIDGE_ABI = hre.artifacts.readArtifactSync("L2SharedBridge").abi;
export const L2_STANDARD_TOKEN_PROXY_BYTECODE = hre.artifacts.readArtifactSync("BeaconProxy").bytecode;

export async function publishL2NativeTokenVaultDependencyBytecodesOnL2(
  deployer: Deployer,
  chainId: string,
  gasPrice: BigNumberish
) {
  if (deployer.verbose) {
    console.log("Providing necessary L2 bytecodes");
  }

  const L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE = hre.artifacts.readArtifactSync("UpgradeableBeacon").bytecode;
  const L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE = hre.artifacts.readArtifactSync("L2StandardERC20").bytecode;

<<<<<<< HEAD
  const receipt = await (
    await publishBytecodeFromL1(
=======
  await publishBytecodeFromL1(
    chainId,
    deployer.deployWallet,
    [
      L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE,
      L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE,
      L2_STANDARD_TOKEN_PROXY_BYTECODE,
    ],
    gasPrice
  );

  if (deployer.verbose) {
    console.log("Bytecodes published on L2");
  }
}

export async function deploySharedBridgeImplOnL2ThroughL1(
  deployer: Deployer,
  chainId: string,
  gasPrice: BigNumberish,
  localLegacyBridgeTesting: boolean = false
) {
  if (deployer.verbose) {
    console.log("Deploying L2SharedBridge Implementation");
  }
  const eraChainId = process.env.CONTRACTS_ERA_CHAIN_ID;

  const l2SharedBridgeImplementationBytecode = localLegacyBridgeTesting
    ? hre.artifacts.readArtifactSync("DevL2SharedBridge").bytecode
    : hre.artifacts.readArtifactSync("L2SharedBridge").bytecode;

  if (!l2SharedBridgeImplementationBytecode) {
    throw new Error("l2SharedBridgeImplementationBytecode not found");
  }
  if (deployer.verbose) {
    console.log("l2SharedBridgeImplementationBytecode loaded");

    console.log("Computing L2SharedBridge Implementation Address");
  }
  const l2SharedBridgeImplAddress = computeL2Create2Address(
    deployer.deployWallet,
    l2SharedBridgeImplementationBytecode,
    defaultAbiCoder.encode(["uint256"], [eraChainId]),
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
    l2SharedBridgeImplementationBytecode,
    defaultAbiCoder.encode(["uint256"], [eraChainId]),
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

export async function deploySharedBridgeProxyOnL2ThroughL1(
  deployer: Deployer,
  chainId: string,
  gasPrice: BigNumberish,
  localLegacyBridgeTesting: boolean = false
) {
  const l1SharedBridge = deployer.defaultSharedBridge(deployer.deployWallet);
  if (deployer.verbose) {
    console.log("Deploying L2SharedBridge Proxy");
  }
  /// prepare proxyInitializationParams
  const l2GovernorAddress = applyL1ToL2Alias(deployer.addresses.Governance);

  let proxyInitializationParams;
  if (localLegacyBridgeTesting) {
    const l2SharedBridgeInterface = new Interface(hre.artifacts.readArtifactSync("DevL2SharedBridge").abi);
    proxyInitializationParams = l2SharedBridgeInterface.encodeFunctionData("initializeDevBridge", [
      l1SharedBridge.address,
      deployer.addresses.Bridges.ERC20BridgeProxy,
      hashL2Bytecode(L2_STANDARD_TOKEN_PROXY_BYTECODE),
      l2GovernorAddress,
    ]);
  } else {
    const l2SharedBridgeInterface = new Interface(hre.artifacts.readArtifactSync("L2SharedBridge").abi);
    proxyInitializationParams = l2SharedBridgeInterface.encodeFunctionData("initialize", [
      l1SharedBridge.address,
      deployer.addresses.Bridges.ERC20BridgeProxy,
      hashL2Bytecode(L2_STANDARD_TOKEN_PROXY_BYTECODE),
      l2GovernorAddress,
    ]);
  }

  /// prepare constructor data
  const l2SharedBridgeProxyConstructorData = ethers.utils.arrayify(
    new ethers.utils.AbiCoder().encode(
      ["address", "address", "bytes"],
      [deployer.addresses.Bridges.L2SharedBridgeImplementation, l2GovernorAddress, proxyInitializationParams]
    )
  );

  /// loading TransparentUpgradeableProxy bytecode
  const L2_SHARED_BRIDGE_PROXY_BYTECODE = hre.artifacts.readArtifactSync(
    "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"
  ).bytecode;

  /// compute L2SharedBridgeProxy address
  const l2SharedBridgeProxyAddress = computeL2Create2Address(
    deployer.deployWallet,
    L2_SHARED_BRIDGE_PROXY_BYTECODE,
    l2SharedBridgeProxyConstructorData,
    ethers.constants.HashZero
  );
  deployer.addresses.Bridges.L2SharedBridgeProxy = l2SharedBridgeProxyAddress;

  /// deploy L2SharedBridgeProxy
  // TODO: request from API how many L2 gas needs for the transaction.
  const tx3 = await create2DeployFromL1(
    chainId,
    deployer.deployWallet,
    L2_SHARED_BRIDGE_PROXY_BYTECODE,
    l2SharedBridgeProxyConstructorData,
    ethers.constants.HashZero,
    priorityTxMaxGasLimit,
    gasPrice
  );
  await tx3.wait();
  if (deployer.verbose) {
    console.log(`CONTRACTS_L2_SHARED_BRIDGE_ADDR=${l2SharedBridgeProxyAddress}`);
  }
}

export async function initializeChainGovernance(deployer: Deployer, chainId: string) {
  const l1SharedBridge = deployer.defaultSharedBridge(deployer.deployWallet);

  if (deployer.verbose) {
    console.log("Initializing chain governance");
  }
  await deployer.executeUpgrade(
    l1SharedBridge.address,
    0,
    l1SharedBridge.interface.encodeFunctionData("initializeChainGovernance", [
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
      chainId,
      deployer.deployWallet,
      [
        L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE,
        L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE,
        L2_STANDARD_TOKEN_PROXY_BYTECODE,
      ],
      gasPrice
    )
  ).wait();

  if (deployer.verbose) {
    console.log("Bytecodes published on L2, hash: ", receipt.transactionHash);
  }
}

async function setL2TokenBeacon(deployer: Deployer, chainId: string, gasPrice: BigNumberish) {
  if (deployer.verbose) {
    console.log("Setting L2 token beacon");
  }
  const l2NTV = L2NativeTokenVaultFactory.connect(L2_NATIVE_TOKEN_VAULT_ADDRESS, deployer.deployWallet);

  const receipt = await deployer.executeUpgradeOnL2(
    chainId,
    L2_NATIVE_TOKEN_VAULT_ADDRESS,
    gasPrice,
    l2NTV.interface.encodeFunctionData("setL2TokenBeacon", [false, ethers.constants.AddressZero]),
    priorityTxMaxGasLimit
  );
  if (deployer.verbose) {
    console.log("Set L2Token Beacon, upgrade hash", receipt.transactionHash);
  }
  const bridgehub = BridgehubFactory.connect(L2_BRIDGEHUB_ADDRESS, deployer.deployWallet);
  const receipt2 = await deployer.executeUpgradeOnL2(
    chainId,
    L2_BRIDGEHUB_ADDRESS,
    gasPrice,
    bridgehub.interface.encodeFunctionData("setAddresses", [
      L2_ASSET_ROUTER_ADDRESS,
      ADDRESS_ONE,
      L2_MESSAGE_ROOT_ADDRESS,
    ]),
    priorityTxMaxGasLimit
  );
  if (deployer.verbose) {
    console.log("Set addresses in BH, upgrade hash", receipt2.transactionHash);
  }
}

export async function deploySharedBridgeOnL2ThroughL1(deployer: Deployer, chainId: string, gasPrice: BigNumberish) {
  await publishL2NativeTokenVaultDependencyBytecodesOnL2(deployer, chainId, gasPrice);
  await setL2TokenBeacon(deployer, chainId, gasPrice);
  if (deployer.verbose) {
    console.log(`CONTRACTS_L2_NATIVE_TOKEN_VAULT_IMPL_ADDR=${L2_NATIVE_TOKEN_VAULT_ADDRESS}`);
    console.log(`CONTRACTS_L2_NATIVE_TOKEN_VAULT_PROXY_ADDR=${L2_NATIVE_TOKEN_VAULT_ADDRESS}`);
    console.log(`CONTRACTS_L2_SHARED_BRIDGE_IMPL_ADDR=${L2_ASSET_ROUTER_ADDRESS}`);
    console.log(`CONTRACTS_L2_SHARED_BRIDGE_ADDR=${L2_ASSET_ROUTER_ADDRESS}`);
  }
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("deploy-shared-bridge-on-l2-through-l1");

  program
    .option("--private-key <private-key>")
    .option("--chain-id <chain-id>")
    .option("--local-legacy-bridge-testing")
    .option("--gas-price <gas-price>")
    .option("--nonce <nonce>")
    .option("--erc20-bridge <erc20-bridge>")
    .option("--skip-initialize-chain-governance <skip-initialize-chain-governance>")
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

      const skipInitializeChainGovernance =
        !!cmd.skipInitializeChainGovernance && cmd.skipInitializeChainGovernance === "true";
      if (skipInitializeChainGovernance) {
        console.log("Initialization of the chain governance will be skipped");
      }

      await deploySharedBridgeOnL2ThroughL1(deployer, chainId, gasPrice);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
