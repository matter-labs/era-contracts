import { Command } from "commander";
import { ethers, Wallet } from "ethers";
import { formatUnits, Interface, parseUnits } from "ethers/lib/utils";
import {
  computeL2Create2Address,
  create2DeployFromL1,
  ethTestConfig,
  provider,
  priorityTxMaxGasLimit,
  hashL2Bytecode,
  applyL1ToL2Alias,
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
} from "./utils";

import { ADDRESS_ONE } from "../../l1-contracts/src.ts/utils";
import { Deployer } from "../../l1-contracts/src.ts/deploy";
import { GAS_MULTIPLIER } from "../../l1-contracts/scripts/utils";
import * as hre from "hardhat";

export async function deploySharedBridgeOnL2ThroughL1(deployer: Deployer, chainId: string, gasPrice: ethers.BigNumber) {
  const l1SharedBridge = deployer.defaultSharedBridge(deployer.deployWallet);

  /// ####################################################################################################################

  if (deployer.verbose) {
    console.log("Providing necessary L2 bytecodes");
  }
  const bridgehub = deployer.bridgehubContract(deployer.deployWallet);

  const requiredValueToPublishBytecodes = await bridgehub.l2TransactionBaseCost(
    chainId,
    gasPrice,
    priorityTxMaxGasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );

  const ethIsBaseToken = ADDRESS_ONE == deployer.addresses.BaseToken;

  if (!ethIsBaseToken) {
    const erc20 = deployer.baseTokenContract(deployer.deployWallet);

    const approveTx = await erc20.approve(
      deployer.addresses.Bridges.SharedBridgeProxy,
      requiredValueToPublishBytecodes.add(requiredValueToPublishBytecodes)
    );
    await approveTx.wait(1);
  }
  const nonce = await deployer.deployWallet.getTransactionCount();
  const L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE = hre.artifacts.readArtifactSync("UpgradeableBeacon").bytecode;
  const L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE = hre.artifacts.readArtifactSync("L2StandardERC20").bytecode;

  const tx1 = await bridgehub.requestL2TransactionDirect(
    {
      chainId,
      l2Contract: ethers.constants.AddressZero,
      mintValue: requiredValueToPublishBytecodes,
      l2Value: 0,
      l2Calldata: "0x",
      l2GasLimit: priorityTxMaxGasLimit,
      l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
      factoryDeps: [L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE, L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE],
      refundRecipient: deployer.deployWallet.address,
    },
    { gasPrice, nonce, value: ethIsBaseToken ? requiredValueToPublishBytecodes : 0 }
  );
  await tx1.wait();
  if (deployer.verbose) {
    console.log("Bytecodes published on L2");
  }
  /// ####################################################################################################################
  if (deployer.verbose) {
    console.log("Deploying L2SharedBridge Implementation");
  }
  const L2_SHARED_BRIDGE_IMPLEMENTATION_BYTECODE = hre.artifacts.readArtifactSync("L2SharedBridge").bytecode;

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
    "0x",
    ethers.constants.HashZero
  );
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
    "0x",
    ethers.constants.HashZero,
    priorityTxMaxGasLimit,
    gasPrice,
    [L2_STANDARD_TOKEN_PROXY_BYTECODE]
  );

  await tx2.wait();
  if (deployer.verbose) {
    console.log("Deployed L2SharedBridge Implementation");
  }
  /// ####################################################################################################################
  if (deployer.verbose) {
    console.log("Deploying L2SharedBridge Proxy");
  }
  /// prepare proxyInitializationParams
  const l2GovernorAddress = applyL1ToL2Alias(deployer.addresses.Governance);
  const BEACON_PROXY_BYTECODE = hre.artifacts.readArtifactSync("BeaconProxy").bytecode;
  const l2SharedBridgeInterface = new Interface(hre.artifacts.readArtifactSync("L2SharedBridge").abi);
  // console.log("kl todo l2GovernorAddress", l2GovernorAddress, deployer.addresses.Governance)
  const proxyInitializationParams = l2SharedBridgeInterface.encodeFunctionData("initialize", [
    l1SharedBridge.address,
    ethers.constants.AddressZero,
    hashL2Bytecode(BEACON_PROXY_BYTECODE),
    l2GovernorAddress,
  ]);

  /// prepare constructor data
  const l2SharedBridgeProxyConstructorData = ethers.utils.arrayify(
    new ethers.utils.AbiCoder().encode(
      ["address", "address", "bytes"],
      [l2SharedBridgeImplAddress, l2GovernorAddress, proxyInitializationParams]
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
  /// ####################################################################################################################

  if (deployer.verbose) {
    console.log("Initializing chain governance");
  }
  await deployer.executeUpgrade(
    l1SharedBridge.address,
    0,
    l1SharedBridge.interface.encodeFunctionData("initializeChainGovernance", [chainId, l2SharedBridgeProxyAddress])
  );

  if (deployer.verbose) {
    console.log("L2 shared bridge address registered on L1 via governance");
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
