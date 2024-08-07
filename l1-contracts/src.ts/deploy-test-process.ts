// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import "@nomiclabs/hardhat-ethers";
import * as ethers from "ethers";
import type { BigNumberish, Wallet } from "ethers";
import { Interface } from "ethers/lib/utils";
import * as zkethers from "zksync-ethers";
import { ETH_ADDRESS_IN_CONTRACTS } from "zksync-ethers/build/utils";
import * as fs from "fs";

import type { FacetCut } from "./diamondCut";
import { Deployer } from "./deploy";
import {
  L2_BOOTLOADER_BYTECODE_HASH,
  L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
  initialBridgehubDeployment,
  registerHyperchain,
} from "./deploy-process";
import { deployTokens, getTokens } from "./deploy-token";

import { SYSTEM_CONFIG } from "../scripts/utils";
import {
  testConfigPath,
  getNumberFromEnv,
  getHashFromEnv,
  PubdataPricingMode,
  ADDRESS_ONE,
  EMPTY_STRING_KECCAK,
} from "./utils";
import { diamondCut, getCurrentFacetCutsForAdd, facetCut, Action } from "./diamondCut";
import { CONTRACTS_GENESIS_PROTOCOL_VERSION } from "../test/unit_tests/utils";

import { DummyAdminFacetNoOverlapFactory } from "../typechain";

const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: "utf-8" }));
const testnetTokenPath = `${testConfigPath}/hardhat.json`;

export async function loadDefaultEnvVarsForTests(deployWallet: Wallet) {
  process.env.CONTRACTS_GENESIS_PROTOCOL_SEMANTIC_VERSION = "0.21.0";
  process.env.CONTRACTS_GENESIS_ROOT = "0x0000000000000000000000000000000000000000000000000000000000000001";
  process.env.CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX = "1";
  process.env.CONTRACTS_GENESIS_BATCH_COMMITMENT = "0x0000000000000000000000000000000000000000000000000000000000000001";
  // process.env.CONTRACTS_GENESIS_UPGRADE_ADDR = ADDRESS_ONE;
  process.env.CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT = "72000000";
  process.env.CONTRACTS_FRI_RECURSION_NODE_LEVEL_VK_HASH = ethers.constants.HashZero;
  process.env.CONTRACTS_FRI_RECURSION_LEAF_LEVEL_VK_HASH = ethers.constants.HashZero;
  // process.env.CONTRACTS_SHARED_BRIDGE_UPGRADE_STORAGE_SWITCH = "1";
  process.env.ETH_CLIENT_CHAIN_ID = (await deployWallet.getChainId()).toString();
  process.env.CONTRACTS_ERA_CHAIN_ID = "270";
  process.env.CONTRACTS_ERA_DIAMOND_PROXY_ADDR = ADDRESS_ONE;
  // CONTRACTS_ERA_DIAMOND_PROXY_ADDR;
  process.env.CONTRACTS_L2_SHARED_BRIDGE_ADDR = ADDRESS_ONE;
  process.env.CONTRACTS_L2_SHARED_BRIDGE_IMPL_ADDR = ADDRESS_ONE;
  process.env.CONTRACTS_L2_ERC20_BRIDGE_ADDR = ADDRESS_ONE;
  process.env.CONTRACTS_BRIDGEHUB_PROXY_ADDR = ADDRESS_ONE;
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

// This is used to deploy the diamond and bridge such that they can be upgraded using UpgradeHyperchain.sol
// This should be deleted after the migration
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
  nonce++;

  await deployer.deployChainAdmin(create2Salt, { gasPrice, nonce });
  await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });
  await deployer.deployBlobVersionedHashRetriever(create2Salt, { gasPrice });

  // note we should also deploy the old ERC20Bridge here, but we can do that later.

  // // for Era we first deploy the DiamondProxy manually, set the vars manually,
  // // and register it in the system via STM.registerAlreadyDeployedStateTransition and bridgehub.createNewChain(ERA_CHAIN_ID, ..)
  // // note we just deploy the STM to get the storedBatchZero

  await deployer.deployDiamondProxy(extraFacets, {});
  // we have to know the address of the diamond proxy in the mailbox so we separate the deployment
  const diamondAdminFacet = await hardhat.ethers.getContractAt(
    "DummyAdminFacetNoOverlap",
    deployer.addresses.StateTransition.DiamondProxy
  );

  await deployer.deployStateTransitionDiamondFacets(create2Salt);
  await diamondAdminFacet.executeUpgradeNoOverlap(await deployer.upgradeZkSyncHyperchainDiamondCut());
  return deployer;
}

/// This is used to deploy the ecosystem contracts with a diamond proxy address that is equal to ERA_DIAMOND_PROXY_ADDR.
/// For this we have to deploy diamond proxy, deploy facets and other contracts, and initializing the diamond proxy using DiamondInit,
/// and registering it in the ecosystem.
/// This is used to test the legacy L1ERC20Bridge, so this should not be deleted after the migration
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
  await deployer.deployDiamondProxy(extraFacets, {});
  // deploy normal contracts
  await initialBridgehubDeployment(deployer, extraFacets, gasPrice, false);
  // for Era we first deploy the DiamondProxy manually, set the vars manually, and register it in the system via bridgehub.createNewChain(ERA_CHAIN_ID, ..)
  if (deployer.verbose) {
    console.log("Applying DiamondCut");
  }
  const diamondAdminFacet = await hardhat.ethers.getContractAt(
    "DummyAdminFacetNoOverlap",
    deployer.addresses.StateTransition.DiamondProxy
  );
  await diamondAdminFacet.executeUpgradeNoOverlap(await deployer.upgradeZkSyncHyperchainDiamondCut());

  const stateTransitionManager = deployer.stateTransitionManagerContract(deployer.deployWallet);
  const registerData = stateTransitionManager.interface.encodeFunctionData("registerAlreadyDeployedHyperchain", [
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
    ethTxOptions.gasPrice ??= 89_990_000; // to fix gasPrice
    const chainId = getNumberFromEnv("ETH_CLIENT_CHAIN_ID");
    const dummyAdminAddress = await this.deployViaCreate2(
      "DummyAdminFacetNoOverlap",
      [],
      ethers.constants.HashZero,
      ethTxOptions
    );

    const adminFacet = await hardhat.ethers.getContractAt("DummyAdminFacetNoOverlap", dummyAdminAddress);
    let facetCuts: FacetCut[] = [facetCut(adminFacet.address, adminFacet.interface, Action.Add, false)];
    facetCuts = facetCuts.concat(extraFacets ?? []);
    const contractAddress = await this.deployViaCreate2(
      "DiamondProxy",
      [chainId, diamondCut(facetCuts, ethers.constants.AddressZero, "0x")],
      ethers.constants.HashZero,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_DIAMOND_PROXY_ADDR=${contractAddress}`);
    }
    process.env.CONTRACTS_ERA_DIAMOND_PROXY_ADDR = contractAddress;
    this.addresses.StateTransition.DiamondProxy = contractAddress;
    this.chainId = parseInt(getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID"));

    /// we fund the diamond proxy so we can test the receive ether function
    if (this.verbose) {
      console.log("Depositing ether");
    }
    const diamondAdminFacet = DummyAdminFacetNoOverlapFactory.connect(contractAddress, this.deployWallet);
    const tx = await diamondAdminFacet.receiveEther({ value: 1000 });
    await tx.wait();
  }

  public async upgradeZkSyncHyperchainDiamondCut(extraFacets?: FacetCut[]) {
    let facetCuts: FacetCut[] = Object.values(
      await getCurrentFacetCutsForAdd(
        this.addresses.StateTransition.AdminFacet,
        this.addresses.StateTransition.GettersFacet,
        this.addresses.StateTransition.MailboxFacet,
        this.addresses.StateTransition.ExecutorFacet
      )
    );
    facetCuts = facetCuts.concat(extraFacets ?? []);

    const verifierParams = {
      recursionNodeLevelVkHash: getHashFromEnv("CONTRACTS_FRI_RECURSION_NODE_LEVEL_VK_HASH"),
      recursionLeafLevelVkHash: getHashFromEnv("CONTRACTS_FRI_RECURSION_LEAF_LEVEL_VK_HASH"),
      recursionCircuitsSetVksHash: "0x0000000000000000000000000000000000000000000000000000000000000000",
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
        [
          "tuple(uint64 batchNumber, bytes32 batchHash, uint64 indexRepeatedStorageChanges, uint256 numberOfLayer1Txs, bytes32 priorityOperationsHash, bytes32 l2LogsTreeRoot, uint256 timestamp, bytes32 commitment)",
        ],
        [
          {
            batchNumber: "0",
            batchHash: getHashFromEnv("CONTRACTS_GENESIS_ROOT"),
            indexRepeatedStorageChanges: getNumberFromEnv("CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX"),
            numberOfLayer1Txs: ethers.constants.HashZero,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: ethers.constants.HashZero,
            timestamp: ethers.constants.HashZero,
            commitment: getHashFromEnv("CONTRACTS_GENESIS_BATCH_COMMITMENT"),
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
