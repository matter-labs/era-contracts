import { Command } from "commander";
import type { BigNumberish } from "ethers";
import { Wallet } from "ethers";
import { formatUnits, parseUnits } from "ethers/lib/utils";
import { provider, publishBytecodeFromL1, priorityTxMaxGasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA } from "./utils";

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
} from "../../l1-contracts/src.ts/constants";

import { L2NativeTokenVaultFactory } from "../typechain";
import { BridgehubFactory, L1AssetRouterFactory, L1NativeTokenVaultFactory } from "../../l1-contracts/typechain";
import { ETH_ADDRESS_IN_CONTRACTS, L2_BASE_TOKEN_ADDRESS } from "zksync-ethers/build/utils";

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

  const receipt = await (
    await publishBytecodeFromL1(
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
    l2NTV.interface.encodeFunctionData("setL2TokenBeacon"),
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
  if (deployer.addresses.BaseToken == ETH_ADDRESS_IN_CONTRACTS) {
    const l1AssetRouter = L1AssetRouterFactory.connect(
      deployer.addresses.Bridges.SharedBridgeProxy,
      deployer.deployWallet
    );
    const l1Ntv = L1NativeTokenVaultFactory.connect(
      deployer.addresses.Bridges.NativeTokenVaultProxy,
      deployer.deployWallet
    );
    const ethAssetId = await l1Ntv.getAssetId(ETH_ADDRESS_IN_CONTRACTS);
    const l1Bridgehub = BridgehubFactory.connect(deployer.addresses.Bridgehub.BridgehubProxy, deployer.deployWallet);
    const value = await l1Bridgehub.l2TransactionBaseCost(
      chainId,
      gasPrice,
      priorityTxMaxGasLimit,
      REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    );
    /// Fixme: this only works for eth based chains atm.
    const receipt3 = await deployer.executeUpgrade(
      l1AssetRouter.address,
      value,
      l1AssetRouter.interface.encodeFunctionData("setAssetHandlerAddressOnCounterPart", [
        chainId,
        value,
        priorityTxMaxGasLimit,
        REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
        deployer.deployWallet.address,
        ethAssetId,
        L2_BASE_TOKEN_ADDRESS,
      ])
    );
    if (deployer.verbose) {
      console.log("Set baseToken assetId in L2AR, upgrade hash", receipt3.transactionHash);
    }
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
