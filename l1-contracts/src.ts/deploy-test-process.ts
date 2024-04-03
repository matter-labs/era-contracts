// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";
import * as ethers from "ethers";
import type { BigNumberish, Wallet } from "ethers";
import type { FacetCut } from "./diamondCut";

import { SYSTEM_CONFIG } from "../scripts/utils";
import { testConfigPath, getNumberFromEnv, getHashFromEnv, PubdataPricingMode, ADDRESS_ONE } from "../src.ts/utils";
import { Deployer } from "./deploy";
import { Interface } from "ethers/lib/utils";
import { deployTokens, getTokens } from "./deploy-token";
import {
  L2_BOOTLOADER_BYTECODE_HASH,
  L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
  initialBridgehubDeployment,
  registerHyperchain,
} from "./deploy-process";
import { diamondCut, getCurrentFacetCutsForAdd, facetCut, Action } from "./diamondCut";
import * as fs from "fs";
import { ETH_ADDRESS_IN_CONTRACTS } from "zksync-ethers/build/src/utils";
import { CONTRACTS_GENESIS_PROTOCOL_VERSION } from "../test/unit_tests/utils";
// import { DummyAdminFacet } from "../typechain";
import * as zkethers from "zksync-ethers";

const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: "utf-8" }));
const testnetTokenPath = `${testConfigPath}/hardhat.json`;

export async function loadDefaultEnvVarsForTests(deployWallet: Wallet) {
  process.env.CONTRACTS_GENESIS_PROTOCOL_VERSION = (21).toString();
  process.env.CONTRACTS_GENESIS_ROOT = ethers.constants.HashZero;
  process.env.CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX = "0";
  process.env.CONTRACTS_GENESIS_BATCH_COMMITMENT = ethers.constants.HashZero;
  // process.env.CONTRACTS_GENESIS_UPGRADE_ADDR = ADDRESS_ONE;
  process.env.CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT = "72000000";
  process.env.CONTRACTS_RECURSION_NODE_LEVEL_VK_HASH = ethers.constants.HashZero;
  process.env.CONTRACTS_RECURSION_LEAF_LEVEL_VK_HASH = ethers.constants.HashZero;
  process.env.CONTRACTS_RECURSION_CIRCUITS_SET_VKS_HASH = ethers.constants.HashZero;
  // process.env.CONTRACTS_SHARED_BRIDGE_UPGRADE_STORAGE_SWITCH = "1";
  process.env.ETH_CLIENT_CHAIN_ID = (await deployWallet.getChainId()).toString();
  process.env.CONTRACTS_ERA_CHAIN_ID = "9";
  process.env.CONTRACTS_L2_SHARED_BRIDGE_ADDR = ADDRESS_ONE;
}

export async function defaultDeployerForTests(deployWallet: Wallet, ownerAddress: string): Promise<Deployer> {
  return new Deployer({
    deployWallet,
    ownerAddress,
    verbose: false, // change here to view deployment
    addresses: addressConfig,
    bootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
    defaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
  });
}

export async function defaultEraDeployerForTests(deployWallet: Wallet, ownerAddress: string): Promise<EraDeployer> {
  const deployer = new EraDeployer({
    deployWallet,
    ownerAddress,
    verbose: false, // change here to view deployment
    addresses: addressConfig,
    bootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
    defaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
  });
  const l2_rpc_addr = "http://localhost:3050";
  const web3Provider = new zkethers.Provider(l2_rpc_addr);
  web3Provider.pollingInterval = 100; // It's OK to keep it low even on stage.
  deployer.syncWallet = new zkethers.Wallet(deployWallet.privateKey, web3Provider, deployWallet.provider);
  return deployer;
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

  // For tests, the chainId is 9
  deployer.chainId = 9;

  const testnetTokens = getTokens();
  const result = await deployTokens(testnetTokens, deployer.deployWallet, null, false, deployer.verbose);
  fs.writeFileSync(testnetTokenPath, JSON.stringify(result, null, 2));

  // deploy the verifier first
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, true);
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, false);
  await registerHyperchain(deployer, false, extraFacets, gasPrice, baseTokenName);
  return deployer;
}

export async function initialPreUpgradeContractsDeployment(
  deployWallet: Wallet,
  ownerAddress: string,
  gasPrice: BigNumberish,
  extraFacets: FacetCut[]
): Promise<EraDeployer> {
  await loadDefaultEnvVarsForTests(deployWallet);
  const deployer = await defaultEraDeployerForTests(deployWallet, ownerAddress);
  deployer.chainId = 9;

  const testnetTokens = getTokens();
  const result = await deployTokens(testnetTokens, deployer.deployWallet, null, false, deployer.verbose);
  fs.writeFileSync(testnetTokenPath, JSON.stringify(result, null, 2));

  let nonce = await deployer.deployWallet.getTransactionCount();
  const create2Salt = ethers.utils.hexlify(ethers.utils.randomBytes(32));

  // Create2 factory already deployed on the public networks, only deploy it on local node
  if (process.env.CHAIN_ETH_NETWORK === "localhost" || process.env.CHAIN_ETH_NETWORK === "hardhat") {
    await deployer.deployCreate2Factory({ gasPrice, nonce });
    nonce++;

    await deployer.deployMulticall3(create2Salt, { gasPrice, nonce });
    nonce++;
  }
  await deployer.deployVerifier(create2Salt, { gasPrice, nonce });
  nonce++;

  await deployer.deployDefaultUpgrade(create2Salt, {
    gasPrice,
    nonce,
  });
  nonce++;

  await deployer.deployGovernance(create2Salt, { gasPrice, nonce });
  await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });
  await deployer.deployBlobVersionedHashRetriever(create2Salt, { gasPrice });

  // /// note the weird order is ok, it mimics historical deployment process
  await deployer.deployERC20BridgeProxy(create2Salt, { gasPrice });

  // // for Era we first deploy the DiamondProxy manually, set the vars manually,
  // // and register it in the system via STM.registerAlreadyDeployedStateTransition and bridgehub.createNewChain(ERA_CHAIN_ID, ..)
  // // note we just deploy the STM to get the storedBatchZero
  await deployer.deployStateTransitionDiamondFacets(create2Salt);
  // await deployer.deployStateTransitionManagerImplementation(create2Salt, {  });
  // await deployer.deployStateTransitionManagerProxy(create2Salt, {  }, extraFacets);

  await deployer.deployDiamondProxy(extraFacets, {});

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
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, true);
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, false);
  // for Era we first deploy the DiamondProxy manually, set the vars manually, and register it in the system via bridgehub.createNewChain(ERA_CHAIN_ID, ..)
  await deployer.deployDiamondProxy(extraFacets, {});
  const stateTransitionManager = deployer.stateTransitionManagerContract(deployer.deployWallet);
  const registerData = stateTransitionManager.interface.encodeFunctionData("registerAlreadyDeployedStateTransition", [
    deployer.chainId,
    deployer.addresses.StateTransition.DiamondProxy,
  ]);
  await deployer.executeUpgrade(deployer.addresses.StateTransition.StateTransitionProxy, 0, registerData);
  await registerHyperchain(deployer, false, extraFacets, gasPrice, baseTokenName, deployer.chainId.toString());
  return deployer;
}

export class EraDeployer extends Deployer {
  public syncWallet: zkethers.Wallet;
  public async deployDiamondProxy(extraFacets: FacetCut[], ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    ethTxOptions.gasPrice ??= 30_000_000; // to fix gasPrice
    const chainId = getNumberFromEnv("ETH_CLIENT_CHAIN_ID");
    const dummyAdminAddress = await this.deployViaCreate2(
      "DummyAdminFacet",
      [],
      ethers.constants.HashZero,
      ethTxOptions
    );

    const adminFacet = await hardhat.ethers.getContractAt("DummyAdminFacet", dummyAdminAddress);
    let facetCuts: FacetCut[] = [facetCut(adminFacet.address, adminFacet.interface, Action.Add, false)];
    facetCuts = facetCuts.concat(extraFacets ?? []);
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
    this.chainId = parseInt(getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID"));
    // notably, the DummyAdminFacet does not depend on the contracts containing the ERA_Diamond_Proxy address
    const diamondAdminFacet = await hardhat.ethers.getContractAt("DummyAdminFacet2", contractAddress);
    // we separate the main diamond cut into an upgrade ( as this was copied from the the old diamond cut )
    await diamondAdminFacet.executeUpgrade2(await this.upgradeZkSyncStateTransitionDiamondCut());
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
    const storedBatchZero = ethers.utils.keccak256(
      new ethers.utils.AbiCoder().encode(
        ["tuple(uint64 a, bytes32 b, uint64 c, uint256 d, bytes32 e, bytes32 f, uint256 g, bytes32 h)"],
        [
          {
            a: "0",
            b: getHashFromEnv("CONTRACTS_GENESIS_ROOT"),
            c: getNumberFromEnv("CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX"),
            d: ethers.constants.HashZero,
            e: "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
            f: ethers.constants.HashZero,
            g: ethers.constants.HashZero,
            h: getHashFromEnv("CONTRACTS_GENESIS_BATCH_COMMITMENT"),
          },
        ]
      )
    );

    const diamondInitCalldata = DiamondInit.encodeFunctionData("initialize", [
      // these first values are set in the contract
      {
        chainId: this.chainId, // era chain Id
        bridgehub: this.addresses.Bridgehub.BridgehubProxy,
        stateTransitionManager: this.addresses.StateTransition.StateTransitionProxy,
        protocolVersion: CONTRACTS_GENESIS_PROTOCOL_VERSION,
        admin: this.ownerAddress,
        validatorTimelock: ADDRESS_ONE,
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
