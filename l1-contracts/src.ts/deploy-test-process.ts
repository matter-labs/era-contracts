// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";
import * as ethers from "ethers";
import type { BigNumberish, Wallet } from "ethers";
import type { FacetCut } from "./diamondCut";

import { SYSTEM_CONFIG } from "../scripts/utils";
import { testConfigPath, getNumberFromEnv, getHashFromEnv, PubdataPricingMode } from "../src.ts/utils";
import { Deployer } from "./deploy";
import { Interface } from "ethers/lib/utils";
import { deployTokens, getTokens } from "./deploy-token";
import {
  L2_BOOTLOADER_BYTECODE_HASH,
  L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
  loadDefaultEnvVarsForTests,
  initialBridgehubDeployment,
  registerHyperchain,
} from "./deploy-process";
import { diamondCut, getCurrentFacetCutsForAdd, facetCut, Action } from "./diamondCut";
import * as fs from "fs";
import { ETH_ADDRESS_IN_CONTRACTS } from "zksync-ethers/build/src/utils";
import { CONTRACTS_LATEST_PROTOCOL_VERSION } from "../test/unit_tests/utils";
// import { DummyAdminFacet } from "../typechain";

const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: "utf-8" }));
const testnetTokenPath = `${testConfigPath}/hardhat.json`;

export async function defaultDeployerForTests(deployWallet: Wallet, ownerAddress: string): Promise<Deployer> {
  return new Deployer({
    deployWallet,
    ownerAddress,
    verbose: false, // change here to view deployement
    addresses: addressConfig,
    bootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
    defaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
  });
}

export async function defaultEraDeployerForTests(deployWallet: Wallet, ownerAddress: string): Promise<EraDeployer> {
  return new EraDeployer({
    deployWallet,
    ownerAddress,
    verbose: false, // change here to view deployement
    addresses: addressConfig,
    bootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
    defaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
  });
}

export async function initialTestnetDeploymentProcess(
  deployWallet: Wallet,
  ownerAddress: string,
  gasPrice: BigNumberish,
  extraFacets: FacetCut[],
  baseTokenName?: string
): Promise<Deployer> {
  await loadDefaultEnvVarsForTests(deployWallet);
  const deployer = await defaultDeployerForTests(deployWallet, ownerAddress);

  const testnetTokens = getTokens();
  const result = await deployTokens(testnetTokens, deployer.deployWallet, null, false, deployer.verbose);
  fs.writeFileSync(testnetTokenPath, JSON.stringify(result, null, 2));

  // deploy the verifier first
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, true, 1);
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, false, 1);
  await registerHyperchain(deployer, false, extraFacets, gasPrice, baseTokenName);
  return deployer;
}

export async function initialEraTestnetDeploymentProcess(
  deployWallet: Wallet,
  ownerAddress: string,
  gasPrice: BigNumberish,
  extraFacets: FacetCut[],
  baseTokenName?: string
): Promise<Deployer> {
  await loadDefaultEnvVarsForTests(deployWallet);
  const deployer = await defaultEraDeployerForTests(deployWallet, ownerAddress);
  deployer.chainId = 9;

  const testnetTokens = getTokens();
  const result = await deployTokens(testnetTokens, deployer.deployWallet, null, false, deployer.verbose);
  fs.writeFileSync(testnetTokenPath, JSON.stringify(result, null, 2));

  // deploy the verifier first
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, true, 1);
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, false, 1);
  deployer.addresses.Create2Factory = "0x1bba393e38a2CD88638F972D67D73599c094f814"; // this should already be deployed, we need to fix it to fix ERA diamond address
  // for Era we first deploy the DiamondProxy manually, set the vars manually, and register it in the system via bridgehub.createNewChain(ERA_CHAIN_ID, ..)
  await deployer.deployDiamondProxy(extraFacets, {});
  const stateTransitionManager = deployer.stateTransitionManagerContract(deployer.deployWallet);
  const tx0 = await stateTransitionManager.registerAlreadyDeployedStateTransition(
    deployer.chainId,
    deployer.addresses.StateTransition.DiamondProxy
  );
  await tx0.wait();
  await registerHyperchain(deployer, false, extraFacets, gasPrice, baseTokenName, deployer.chainId.toString());
  return deployer;
}

class EraDeployer extends Deployer {
  public async deployDiamondProxy(extraFacets: FacetCut[], ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    ethTxOptions.gasPrice ??= 5_000_000; // to fix gasPrice
    const chainId = getNumberFromEnv("ETH_CLIENT_CHAIN_ID");
    const dummyAdminAddress = await this.deployViaCreate2(
      "DummyAdminFacet",
      [],
      ethers.constants.HashZero,
      ethTxOptions
    );

    const adminFacet = await hardhat.ethers.getContractAt("DummyAdminFacet", dummyAdminAddress);
    const facetCuts: FacetCut[] = [facetCut(adminFacet.address, adminFacet.interface, Action.Add, false)];
    const contractAddress = await this.deployViaCreate2(
      "DiamondProxy",
      [chainId, diamondCut(facetCuts, ethers.constants.AddressZero, "0x")],
      ethers.constants.HashZero,
      ethTxOptions
    );

    if (this.verbose) {
      console.log("Copy this CONTRACTS_DIAMOND_PROXY_ADDR to hardhat config as ERA_DIAMOND_PROXY for hardhat");
      console.log(`CONTRACTS_DIAMOND_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.DiamondProxy = contractAddress;
    // notably, the DummyAdminFacet does not depend on the
    const diamondAdminFacet = await hardhat.ethers.getContractAt("DummyAdminFacet", contractAddress);
    await diamondAdminFacet.executeUpgrade2(await this.upgradeZkSyncStateTransitionDiamondCut(extraFacets));
  }

  public async upgradeZkSyncStateTransitionDiamondCut(extraFacets?: FacetCut[]) {
    let facetCuts: FacetCut[] = Object.values(
      await getCurrentFacetCutsForAdd(
        this.addresses.StateTransition.AdminFacet,
        this.addresses.StateTransition.GettersFacet,
        this.addresses.StateTransition.MailboxFacet,
        this.addresses.StateTransition.ExecutorFacet
      )
    );
    facetCuts = facetCuts.concat(extraFacets ?? []);
    // console.log("kl todo", facetCuts);
    const verifierParams =
      process.env["CONTRACTS_PROVER_AT_GENESIS"] == "fri"
        ? {
            recursionNodeLevelVkHash: getHashFromEnv("CONTRACTS_FRI_RECURSION_NODE_LEVEL_VK_HASH"),
            recursionLeafLevelVkHash: getHashFromEnv("CONTRACTS_FRI_RECURSION_LEAF_LEVEL_VK_HASH"),
            recursionCircuitsSetVksHash: "0x0000000000000000000000000000000000000000000000000000000000000000",
          }
        : {
            recursionNodeLevelVkHash: getHashFromEnv("CONTRACTS_RECURSION_NODE_LEVEL_VK_HASH"),
            recursionLeafLevelVkHash: getHashFromEnv("CONTRACTS_RECURSION_LEAF_LEVEL_VK_HASH"),
            recursionCircuitsSetVksHash: getHashFromEnv("CONTRACTS_RECURSION_CIRCUITS_SET_VKS_HASH"),
          };
    const priorityTxMaxGasLimit = getNumberFromEnv("CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT");
    const DiamondInit = new Interface(hardhat.artifacts.readArtifactSync("DiamondInit").abi);

    const feeParams = {
      pubdataPricingMode: PubdataPricingMode.Rollup,
      batchOverheadL1Gas: SYSTEM_CONFIG.priorityTxBatchOverheadL1Gas,
      maxPubdataPerBatch: SYSTEM_CONFIG.priorityTxPubdataPerBatch,
      priorityTxMaxPubdata: SYSTEM_CONFIG.priorityTxMaxPubdata,
      maxL2GasPerBatch: SYSTEM_CONFIG.priorityTxMaxGasPerBatch,
      minimalL2GasPrice: SYSTEM_CONFIG.priorityTxMinimalGasPrice,
    };
    const storedBatchZero = await this.stateTransitionManagerContract(this.deployWallet).storedBatchZero();
    const diamondInitCalldata = DiamondInit.encodeFunctionData("initialize", [
      // these first values are set in the contract
      {
        chainId: this.chainId, // era chain Id
        bridgehub: this.addresses.Bridgehub.BridgehubProxy,
        stateTransitionManager: this.addresses.StateTransition.StateTransitionProxy,
        protocolVersion: CONTRACTS_LATEST_PROTOCOL_VERSION,
        admin: this.ownerAddress,
        validatorTimelock: this.addresses.ValidatorTimeLock,
        baseToken: ETH_ADDRESS_IN_CONTRACTS,
        baseTokenBridge: this.addresses.Bridges.SharedBridgeProxy,
        storedBatchZero,
        verifier: this.addresses.StateTransition.Verifier,
        verifierParams,
        l2BootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
        l2DefaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
        priorityTxMaxGasLimit,
        feeParams,
        blobVersionedHashRetriever: this.addresses.BlobVersionedHashRetriever,
      },
    ]);

    return diamondCut(facetCuts, this.addresses.StateTransition.DiamondInit, diamondInitCalldata);
  }
}
