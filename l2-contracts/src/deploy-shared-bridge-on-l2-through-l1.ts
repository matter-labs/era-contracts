import { Command } from "commander";
import type { BigNumberish } from "ethers";
import { ethers, Wallet } from "ethers";
import { formatUnits, Interface, parseUnits, defaultAbiCoder } from "ethers/lib/utils";
import {
  computeL2Create2Address,
  create2DeployFromL1,
  provider,
  priorityTxMaxGasLimit,
  hashL2Bytecode,
  applyL1ToL2Alias,
  publishBytecodeFromL1,
  requestL2TransactionDirect,
} from "./utils";

import { ethTestConfig } from "./deploy-utils";

import { Deployer } from "../../l1-contracts/src.ts/deploy";
import { GAS_MULTIPLIER } from "../../l1-contracts/scripts/utils";
import * as hre from "hardhat";

export const L2_SHARED_BRIDGE_ABI = hre.artifacts.readArtifactSync("L2SharedBridge").abi;
export const L2_STANDARD_TOKEN_PROXY_BYTECODE = hre.artifacts.readArtifactSync("BeaconProxy").bytecode;

export async function publishL2StandardDeployerDependencyBytecodesOnL2(
  deployer: Deployer,
  chainId: string,
  gasPrice: BigNumberish
) {
  if (deployer.verbose) {
    console.log("Providing necessary L2 bytecodes");
  }

  const L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE = hre.artifacts.readArtifactSync("UpgradeableBeacon").bytecode;
  const L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE = hre.artifacts.readArtifactSync("L2StandardERC20").bytecode;

  const receipt = await publishBytecodeFromL1(
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
    console.log("Bytecodes published on L2, hash: ", receipt.hash);
  }
}

export async function deployL2ProxyAdmin(deployer: Deployer, chainId: string, gasPrice: BigNumberish) {
  if (deployer.verbose) {
    console.log("Deploying L2 ProxyAdmin ");
  }

  const L2ProxyAdminBytecode = hre.artifacts.readArtifactSync("ProxyAdmin").bytecode;

  if (!L2ProxyAdminBytecode) {
    throw new Error("L2 ProxyAdmin not found");
  }
  if (deployer.verbose) {
    console.log("Computing l2 proxy admin Address");
  }
  const L2ProxyAdminAddress = computeL2Create2Address(
    deployer.deployWallet,
    L2ProxyAdminBytecode,
    "0x00",
    ethers.constants.HashZero
  );
  deployer.addresses.L2ProxyAdmin = L2ProxyAdminAddress;
  if (deployer.verbose) {
    console.log(`L2 Proxy Admin  Address: ${L2ProxyAdminAddress}`);
    console.log("Deploying L2 Proxy Admin ");
  }

  // TODO: request from API how many L2 gas needs for the transaction.
  const tx2 = await create2DeployFromL1(
    chainId,
    deployer.deployWallet,
    L2ProxyAdminBytecode,
    "0x00",
    ethers.constants.HashZero,
    priorityTxMaxGasLimit,
    gasPrice,
    []
  );

  await tx2.wait();
  if (deployer.verbose) {
    console.log("Deployed L2 Proxy Admin");
    console.log(`CONTRACTS_L2_PROXY_ADMIN_ADDR=${L2ProxyAdminAddress}`);
  }
}

export async function deployStandardDeployerImplOnL2ThroughL1(
  deployer: Deployer,
  chainId: string,
  gasPrice: BigNumberish
) {
  if (deployer.verbose) {
    console.log("Deploying L2StandardDeployer Implementation");
  }

  const L2StandardDeployerImplementationBytecode = hre.artifacts.readArtifactSync("L2StandardDeployer").bytecode;

  if (!L2StandardDeployerImplementationBytecode) {
    throw new Error("L2StandardDeployerImplementationBytecode not found");
  }
  if (deployer.verbose) {
    console.log("Computing l2StandardDeployer Implementation Address");
  }
  const L2StandardDeployerImplAddress = computeL2Create2Address(
    deployer.deployWallet,
    L2StandardDeployerImplementationBytecode,
    "0x00",
    ethers.constants.HashZero
  );
  deployer.addresses.Bridges.L2StandardDeployerImplementation = L2StandardDeployerImplAddress;
  if (deployer.verbose) {
    console.log(`L2StandardDeployer Implementation Address: ${L2StandardDeployerImplAddress}`);
    console.log("Deploying L2StandardDeployer Implementation");
  }

  /// L2StandardTokenProxy bytecode. We need this bytecode to be accessible on the L2, it is enough to add to factoryDeps
  const L2_STANDARD_TOKEN_PROXY_BYTECODE = hre.artifacts.readArtifactSync("BeaconProxy").bytecode;

  // TODO: request from API how many L2 gas needs for the transaction.
  const tx2 = await create2DeployFromL1(
    chainId,
    deployer.deployWallet,
    L2StandardDeployerImplementationBytecode,
    "0x00",
    ethers.constants.HashZero,
    priorityTxMaxGasLimit,
    gasPrice,
    [L2_STANDARD_TOKEN_PROXY_BYTECODE]
  );

  await tx2.wait();
  if (deployer.verbose) {
    console.log("Deployed L2StandardDeployer Implementation");
    console.log(`CONTRACTS_L2_STANDARD_DEPLOYER_IMPL_ADDR=${L2StandardDeployerImplAddress}`);
  }
}

export async function deployStandardDeployerProxyOnL2ThroughL1(
  deployer: Deployer,
  chainId: string,
  gasPrice: BigNumberish
) {
  if (deployer.verbose) {
    console.log("Deploying L2StandardDeployer Proxy");
  }

  const L2StandardDeployerInterface = new Interface(hre.artifacts.readArtifactSync("L2StandardDeployer").abi);
  const proxyInitializationParams = L2StandardDeployerInterface.encodeFunctionData("initialize", [
    hashL2Bytecode(L2_STANDARD_TOKEN_PROXY_BYTECODE),
    deployer.deployWallet.address,
    false,
  ]);

  /// prepare constructor data
  const L2StandardDeployerProxyConstructorData = ethers.utils.arrayify(
    new ethers.utils.AbiCoder().encode(
      ["address", "address", "bytes"],
      [
        deployer.addresses.Bridges.L2StandardDeployerImplementation,
        deployer.addresses.L2ProxyAdmin,
        proxyInitializationParams,
      ]
    )
  );

  /// loading TransparentUpgradeableProxy bytecode
  const L2_STANDARD_DEPLOYER_PROXY_BYTECODE = hre.artifacts.readArtifactSync("TransparentUpgradeableProxy").bytecode;

  /// compute L2StandardDeployerProxy address
  const L2StandardDeployerProxyAddress = computeL2Create2Address(
    deployer.deployWallet,
    L2_STANDARD_DEPLOYER_PROXY_BYTECODE,
    L2StandardDeployerProxyConstructorData,
    ethers.constants.HashZero
  );
  deployer.addresses.Bridges.L2StandardDeployerProxy = L2StandardDeployerProxyAddress;

  /// deploy L2StandardDeployerProxy
  // TODO: request from API how many L2 gas needs for the transaction.
  const tx3 = await create2DeployFromL1(
    chainId,
    deployer.deployWallet,
    L2_STANDARD_DEPLOYER_PROXY_BYTECODE,
    L2StandardDeployerProxyConstructorData,
    ethers.constants.HashZero,
    priorityTxMaxGasLimit,
    gasPrice,
    []
  );
  await tx3.wait();
  if (deployer.verbose) {
    console.log(`CONTRACTS_L2_STANDARD_DEPLOYER_PROXY_ADDR=${L2StandardDeployerProxyAddress}`);
  }
}

export async function setSharedBridgeInStandardDeployer(deployer: Deployer, chainId: string, gasPrice: BigNumberish) {
  const l2StandardDeployer = L2StandardDeployerFactory.connect(
    deployer.addresses.Bridges.L2StandardDeployerProxy,
    deployer.deployWallet
  );

  const tx1 = await requestL2TransactionDirect(
    chainId,
    deployer.deployWallet,
    deployer.addresses.Bridges.L2StandardDeployerProxy,
    l2StandardDeployer.interface.encodeFunctionData("setSharedBridge", [
      deployer.addresses.Bridges.L2SharedBridgeProxy,
    ]),
    priorityTxMaxGasLimit
  );
  await tx1.wait();
  if (deployer.verbose) {
    console.log("Set L2SharedBridge in L2StandardDeployer");
  }

  const tx2 = await requestL2TransactionDirect(
    chainId,
    deployer.deployWallet,
    deployer.addresses.Bridges.L2StandardDeployerProxy,
    l2StandardDeployer.interface.encodeFunctionData("transferOwnership", [deployer.addresses.Governance]),
    priorityTxMaxGasLimit
  );
  await tx2.wait();
  if (deployer.verbose) {
    console.log("Transferred L2StandardDeployer ownership to governance");
  }

  await deployer.executeUpgradeOnL2(
    chainId,
    deployer.addresses.Bridges.L2StandardDeployerProxy,
    gasPrice,
    l2StandardDeployer.interface.encodeFunctionData("acceptOwnership"),
    priorityTxMaxGasLimit
  );
}

export async function deploySharedBridgeImplOnL2ThroughL1(deployer: Deployer, chainId: string, gasPrice: BigNumberish) {
  if (deployer.verbose) {
    console.log("Deploying L2SharedBridge Implementation");
  }
  const eraChainId = process.env.CONTRACTS_ERA_CHAIN_ID;
  const l1ChainId = process.env.ETH_CLIENT_CHAIN_ID;

  const l2SharedBridgeImplementationBytecode = hre.artifacts.readArtifactSync("L2SharedBridge").bytecode;

  if (!l2SharedBridgeImplementationBytecode) {
    throw new Error("l2SharedBridgeImplementationBytecode not found");
  }
  if (deployer.verbose) {
    console.log("Computing L2SharedBridge Implementation Address");
  }
  const implConstructorData = defaultAbiCoder.encode(["uint256", "uint256"], [eraChainId, l1ChainId]);

  const l2SharedBridgeImplAddress = computeL2Create2Address(
    deployer.deployWallet,
    l2SharedBridgeImplementationBytecode,
    implConstructorData,
    ethers.constants.HashZero
  );
  deployer.addresses.Bridges.L2SharedBridgeImplementation = l2SharedBridgeImplAddress;
  if (deployer.verbose) {
    console.log(`L2SharedBridge Implementation Address: ${l2SharedBridgeImplAddress}`);

    console.log("Deploying L2SharedBridge Implementation");
  }

  // TODO: request from API how many L2 gas needs for the transaction.
  const tx2 = await create2DeployFromL1(
    chainId,
    deployer.deployWallet,
    l2SharedBridgeImplementationBytecode,
    implConstructorData,
    ethers.constants.HashZero,
    priorityTxMaxGasLimit,
    gasPrice,
    []
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
  gasPrice: BigNumberish
) {
  const l1SharedBridge = deployer.defaultSharedBridge(deployer.deployWallet);
  if (deployer.verbose) {
    console.log("Deploying L2SharedBridge Proxy");
  }
  /// prepare proxyInitializationParams
  const l2GovernorAddress = applyL1ToL2Alias(deployer.addresses.Governance);

  const l2SharedBridgeInterface = new Interface(hre.artifacts.readArtifactSync("L2SharedBridge").abi);
  const proxyInitializationParams = l2SharedBridgeInterface.encodeFunctionData("initialize", [
    l1SharedBridge.address,
    deployer.addresses.Bridges.ERC20BridgeProxy,
    deployer.addresses.Bridges.L2StandardDeployerProxy,
  ]);

  /// prepare constructor data
  const l2SharedBridgeProxyConstructorData = ethers.utils.arrayify(
    new ethers.utils.AbiCoder().encode(
      ["address", "address", "bytes"],
      [deployer.addresses.Bridges.L2SharedBridgeImplementation, l2GovernorAddress, proxyInitializationParams]
    )
  );

  /// loading TransparentUpgradeableProxy bytecode
  const L2_SHARED_BRIDGE_PROXY_BYTECODE = hre.artifacts.readArtifactSync("TransparentUpgradeableProxy").bytecode;

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
      chainId,
      deployer.addresses.Bridges.L2SharedBridgeProxy,
    ])
  );

  if (deployer.verbose) {
    console.log("L2 shared bridge address registered on L1 via governance");
  }
}

export async function deploySharedBridgeOnL2ThroughL1(
  deployer: Deployer,
  chainId: string,
  gasPrice: BigNumberish,
  skipInitializeChainGovernance: boolean
) {
  await publishL2StandardDeployerDependencyBytecodesOnL2(deployer, chainId, gasPrice);
  await deployL2ProxyAdmin(deployer, chainId, gasPrice);
  await deployStandardDeployerImplOnL2ThroughL1(deployer, chainId, gasPrice);
  await deployStandardDeployerProxyOnL2ThroughL1(deployer, chainId, gasPrice);
  await deploySharedBridgeImplOnL2ThroughL1(deployer, chainId, gasPrice);
  await deploySharedBridgeProxyOnL2ThroughL1(deployer, chainId, gasPrice);
  await setSharedBridgeInStandardDeployer(deployer, chainId, gasPrice);
  if (!skipInitializeChainGovernance) {
    await initializeChainGovernance(deployer, chainId);
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

      await deploySharedBridgeOnL2ThroughL1(deployer, chainId, gasPrice, skipInitializeChainGovernance);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
