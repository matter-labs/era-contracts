import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";
// import "@matterlabs/hardhat-zksync-ethers";

import type { BigNumberish, providers, Signer, Wallet, Contract } from "ethers";
import { ethers } from "ethers";
import { hexlify, Interface } from "ethers/lib/utils";
import { Wallet as ZkWallet, ContractFactory as ZkContractFactory } from "zksync-ethers";

import type { DeployedAddresses } from "./deploy-utils";
import {
  deployedAddressesFromEnv,
  deployBytecodeViaCreate2 as deployBytecodeViaCreate2EVM,
  deployViaCreate2 as deployViaCreate2EVM,
  create2DeployFromL1,
} from "./deploy-utils";
import {
  deployViaCreate2 as deployViaCreate2Zk,
  BUILT_IN_ZKSYNC_CREATE2_FACTORY,
  L2_STANDARD_ERC20_PROXY_FACTORY,
  L2_STANDARD_ERC20_IMPLEMENTATION,
  L2_STANDARD_TOKEN_PROXY,
  L2_SHARED_BRIDGE_IMPLEMENTATION,
  L2_SHARED_BRIDGE_PROXY,
  // deployBytecodeViaCreate2OnPath,
  // L2_SHARED_BRIDGE_PATH,
} from "./deploy-utils-zk";
import {
  packSemver,
  readBatchBootloaderBytecode,
  readSystemContractsBytecode,
  unpackStringSemVer,
  SYSTEM_CONFIG,
  // web3Provider,
  // web3Url,
} from "../scripts/utils";
import { getTokens } from "./deploy-token";
import {
  ADDRESS_ONE,
  getAddressFromEnv,
  getHashFromEnv,
  getNumberFromEnv,
  PubdataPricingMode,
  hashL2Bytecode,
  DIAMOND_CUT_DATA_ABI_STRING,
  FIXED_FORCE_DEPLOYMENTS_DATA_ABI_STRING,
  REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  compileInitialCutHash,
  readBytecode,
  applyL1ToL2Alias,
  BRIDGEHUB_CTM_ASSET_DATA_ABI_STRING,
  encodeNTVAssetId,
  computeL2Create2Address,
  priorityTxMaxGasLimit,
  isCurrentNetworkLocal,
} from "./utils";
import type { ChainAdminCall } from "./utils";
import { IGovernanceFactory } from "../typechain/IGovernanceFactory";
import { ITransparentUpgradeableProxyFactory } from "../typechain/ITransparentUpgradeableProxyFactory";
import { ProxyAdminFactory } from "../typechain/ProxyAdminFactory";

import { IZKChainFactory } from "../typechain/IZKChainFactory";
import { L1AssetRouterFactory } from "../typechain/L1AssetRouterFactory";
import { L1NullifierDevFactory } from "../typechain/L1NullifierDevFactory";

import { SingletonFactoryFactory } from "../typechain/SingletonFactoryFactory";
import { ValidatorTimelockFactory } from "../typechain/ValidatorTimelockFactory";

import type { FacetCut } from "./diamondCut";
import { getCurrentFacetCutsForAdd } from "./diamondCut";

import { BridgehubFactory, ChainAdminFactory, ERC20Factory, ChainTypeManagerFactory } from "../typechain";

import { IL1AssetRouterFactory } from "../typechain/IL1AssetRouterFactory";
import { IL1NativeTokenVaultFactory } from "../typechain/IL1NativeTokenVaultFactory";
import { IL1NullifierFactory } from "../typechain/IL1NullifierFactory";
import { ICTMDeploymentTrackerFactory } from "../typechain/ICTMDeploymentTrackerFactory";
import { TestnetERC20TokenFactory } from "../typechain/TestnetERC20TokenFactory";

import { RollupL1DAValidatorFactory } from "../../da-contracts/typechain/RollupL1DAValidatorFactory";

let L2_BOOTLOADER_BYTECODE_HASH: string;
let L2_DEFAULT_ACCOUNT_BYTECODE_HASH: string;

export interface DeployerConfig {
  deployWallet: Wallet | ZkWallet;
  addresses?: DeployedAddresses;
  ownerAddress?: string;
  verbose?: boolean;
  bootloaderBytecodeHash?: string;
  defaultAccountBytecodeHash?: string;
  deployedLogPrefix?: string;
  l1Deployer?: Deployer;
  l1ChainId?: string;
}

export interface Operation {
  calls: { target: string; value: BigNumberish; data: string }[];
  predecessor: string;
  salt: string;
}

export type OperationOrString = Operation | string;

export class Deployer {
  public addresses: DeployedAddresses;
  public deployWallet: Wallet | ZkWallet;
  public verbose: boolean;
  public chainId: number;
  public l1ChainId: number;
  public ownerAddress: string;
  public deployedLogPrefix: string;

  public isZkMode(): boolean {
    return this.deployWallet instanceof ZkWallet;
  }

  constructor(config: DeployerConfig) {
    this.deployWallet = config.deployWallet;
    this.verbose = config.verbose != null ? config.verbose : false;
    this.addresses = config.addresses ? config.addresses : deployedAddressesFromEnv();
    L2_BOOTLOADER_BYTECODE_HASH = config.bootloaderBytecodeHash
      ? config.bootloaderBytecodeHash
      : hexlify(hashL2Bytecode(readBatchBootloaderBytecode()));
    L2_DEFAULT_ACCOUNT_BYTECODE_HASH = config.defaultAccountBytecodeHash
      ? config.defaultAccountBytecodeHash
      : hexlify(hashL2Bytecode(readSystemContractsBytecode("DefaultAccount")));
    this.ownerAddress = config.ownerAddress != null ? config.ownerAddress : this.deployWallet.address;
    this.chainId = parseInt(process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID!);
    this.l1ChainId = parseInt(config.l1ChainId || getNumberFromEnv("ETH_CLIENT_CHAIN_ID"));
    this.deployedLogPrefix = config.deployedLogPrefix ?? "CONTRACTS";
  }

  public async initialZkSyncZKChainDiamondCut(extraFacets?: FacetCut[], compareDiamondCutHash: boolean = false) {
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

    const diamondCut = compileInitialCutHash(
      facetCuts,
      verifierParams,
      L2_BOOTLOADER_BYTECODE_HASH,
      L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
      this.addresses.StateTransition.Verifier,
      this.addresses.BlobVersionedHashRetriever,
      +priorityTxMaxGasLimit,
      this.addresses.StateTransition.DiamondInit,
      false
    );

    if (compareDiamondCutHash) {
      const hash = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode([DIAMOND_CUT_DATA_ABI_STRING], [diamondCut])
      );

      console.log(`Diamond cut hash: ${hash}`);
      const ctm = ChainTypeManagerFactory.connect(
        this.addresses.StateTransition.StateTransitionProxy,
        this.deployWallet
      );

      const hashFromCTM = await ctm.initialCutHash();
      if (hash != hashFromCTM) {
        throw new Error(`Has from CTM ${hashFromCTM} does not match the computed hash ${hash}`);
      }
    }

    return diamondCut;
  }

  public async genesisForceDeploymentsData() {
    let bridgehubZKBytecode = ethers.constants.HashZero;
    let assetRouterZKBytecode = ethers.constants.HashZero;
    let nativeTokenVaultZKBytecode = ethers.constants.HashZero;
    let l2TokenProxyBytecodeHash = ethers.constants.HashZero;
    let messageRootZKBytecode = ethers.constants.HashZero;
    if (process.env.CHAIN_ETH_NETWORK != "hardhat") {
      bridgehubZKBytecode = readBytecode("./artifacts-zk/contracts/bridgehub", "Bridgehub");
      assetRouterZKBytecode = readBytecode("./artifacts-zk/contracts/bridge/asset-router", "L2AssetRouter");
      nativeTokenVaultZKBytecode = readBytecode("./artifacts-zk/contracts/bridge/ntv", "L2NativeTokenVault");
      messageRootZKBytecode = readBytecode("./artifacts-zk/contracts/bridgehub", "MessageRoot");
      const l2TokenProxyBytecode = readBytecode(
        "./artifacts-zk/@openzeppelin/contracts-v4/proxy/beacon",
        "BeaconProxy"
      );
      l2TokenProxyBytecodeHash = ethers.utils.hexlify(hashL2Bytecode(l2TokenProxyBytecode));
    }
    const fixedForceDeploymentsData = {
      l1ChainId: getNumberFromEnv("ETH_CLIENT_CHAIN_ID"),
      eraChainId: getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID"),
      l1AssetRouter: this.addresses.Bridges.SharedBridgeProxy,
      l2TokenProxyBytecodeHash: l2TokenProxyBytecodeHash,
      aliasedL1Governance: applyL1ToL2Alias(this.addresses.Governance),
      maxNumberOfZKChains: getNumberFromEnv("CONTRACTS_MAX_NUMBER_OF_ZK_CHAINS"),
      bridgehubBytecodeHash: ethers.utils.hexlify(hashL2Bytecode(bridgehubZKBytecode)),
      l2AssetRouterBytecodeHash: ethers.utils.hexlify(hashL2Bytecode(assetRouterZKBytecode)),
      l2NtvBytecodeHash: ethers.utils.hexlify(hashL2Bytecode(nativeTokenVaultZKBytecode)),
      messageRootBytecodeHash: ethers.utils.hexlify(hashL2Bytecode(messageRootZKBytecode)),
      l2SharedBridgeLegacyImpl: ethers.constants.AddressZero,
      l2BridgedStandardERC20Impl: ethers.constants.AddressZero,
    };

    return ethers.utils.defaultAbiCoder.encode([FIXED_FORCE_DEPLOYMENTS_DATA_ABI_STRING], [fixedForceDeploymentsData]);
  }

  public async updateCreate2FactoryZkMode() {
    if (!this.isZkMode()) {
      throw new Error("`updateCreate2FactoryZkMode` should be only called in Zk mode");
    }

    console.log("Create2Factory is built into zkSync and so won't be deployed separately");
    console.log(`CONTRACTS_CREATE2_FACTORY_ADDR=${BUILT_IN_ZKSYNC_CREATE2_FACTORY}`);
    this.addresses.Create2Factory = BUILT_IN_ZKSYNC_CREATE2_FACTORY;
  }

  public async deployCreate2Factory(ethTxOptions?: ethers.providers.TransactionRequest) {
    if (this.verbose) {
      console.log("Deploying Create2 factory");
    }

    if (this.isZkMode()) {
      throw new Error("Create2Factory is built into zkSync and should not be deployed separately");
    }

    const contractFactory = await hardhat.ethers.getContractFactory("SingletonFactory", {
      signer: this.deployWallet,
    });

    const create2Factory = await contractFactory.deploy(...[ethTxOptions]);
    const rec = await create2Factory.deployTransaction.wait();

    if (this.verbose) {
      console.log(`CONTRACTS_CREATE2_FACTORY_ADDR=${create2Factory.address}`);
      console.log(`Create2 factory deployed, gasUsed: ${rec.gasUsed.toString()}, ${rec.transactionHash}`);
    }

    this.addresses.Create2Factory = create2Factory.address;
  }

  public async deployViaCreate2(
    contractName: string,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    args: any[],
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    libraries?: any,
    bytecode?: ethers.utils.BytesLike
  ) {
    if (this.isZkMode()) {
      if (bytecode != null) {
        return ADDRESS_ONE;
        // note providing bytecode is only for da-contracts on L1, we can skip it here
      }
      const result = await deployViaCreate2Zk(
        this.deployWallet as ZkWallet,
        contractName,
        args,
        create2Salt,
        ethTxOptions,
        this.verbose
      );
      return result[0];
    }

    // For L1 deployments we try to use constant gas limit
    ethTxOptions.gasLimit ??= 10_000_000;
    const result = await deployViaCreate2EVM(
      this.deployWallet,
      contractName,
      args,
      create2Salt,
      ethTxOptions,
      this.addresses.Create2Factory,
      this.verbose,
      libraries,
      bytecode
    );
    return result[0];
  }

  public async loadFromDAFolder(contractName: string) {
    let factory;
    if (contractName == "RollupL1DAValidator") {
      factory = new RollupL1DAValidatorFactory(this.deployWallet);
    } else {
      throw new Error(`Unknown DA contract name ${contractName}`);
    }
    return factory.getDeployTransaction().data;
  }

  private async deployBytecodeViaCreate2(
    contractName: string,
    bytecode: ethers.BytesLike,
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ): Promise<string> {
    if (this.isZkMode()) {
      throw new Error("`deployBytecodeViaCreate2` not supported in zkMode");
    }

    ethTxOptions.gasLimit ??= 10_000_000;

    const result = await deployBytecodeViaCreate2EVM(
      this.deployWallet,
      contractName,
      bytecode,
      create2Salt,
      ethTxOptions,
      this.addresses.Create2Factory,
      this.verbose
    );

    return result[0];
  }

  public async deployGovernance(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const contractAddress = await this.deployViaCreate2(
      "Governance",
      // TODO: load parameters from config
      [this.ownerAddress, ethers.constants.AddressZero, 0],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_GOVERNANCE_ADDR=${contractAddress}`);
    }

    this.addresses.Governance = contractAddress;
  }

  public async deployChainAdmin(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    // Firstly, we deploy the access control restriction for the chain admin
    const accessControlRestriction = await this.deployViaCreate2(
      "AccessControlRestriction",
      [0, this.ownerAddress],
      create2Salt,
      ethTxOptions
    );
    if (this.verbose) {
      console.log(`CONTRACTS_ACCESS_CONTROL_RESTRICTION_ADDR=${accessControlRestriction}`);
    }

    // Then we deploy the ChainAdmin contract itself
    const contractAddress = await this.deployViaCreate2(
      "ChainAdmin",
      [[accessControlRestriction]],
      create2Salt,
      ethTxOptions
    );
    if (this.verbose) {
      console.log(`CONTRACTS_CHAIN_ADMIN_ADDR=${contractAddress}`);
    }
    this.addresses.ChainAdmin = contractAddress;
  }

  public async deployTransparentProxyAdmin(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    if (this.verbose) {
      console.log("Deploying Proxy Admin");
    }
    // Note: we cannot deploy using Create2, as the owner of the ProxyAdmin is msg.sender
    let proxyAdmin;
    let rec;

    if (this.isZkMode()) {
      // @ts-ignore
      // TODO try to make it work with zksync ethers
      const zkWal = this.deployWallet as ZkWallet;
      // TODO: this is a hack
      const tmpContractFactory = await hardhat.ethers.getContractFactory(
        "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol:ProxyAdmin",
        {
          signer: this.deployWallet,
        }
      );
      const contractFactory = new ZkContractFactory(tmpContractFactory.interface, tmpContractFactory.bytecode, zkWal);
      proxyAdmin = await contractFactory.deploy(...[ethTxOptions]);
      rec = await proxyAdmin.deployTransaction.wait();
    } else {
      ethTxOptions.gasLimit ??= 10_000_000;
      const contractFactory = await hardhat.ethers.getContractFactory(
        "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol:ProxyAdmin",
        {
          signer: this.deployWallet,
        }
      );
      proxyAdmin = await contractFactory.deploy(...[ethTxOptions]);
      rec = await proxyAdmin.deployTransaction.wait();
    }

    if (this.verbose) {
      console.log(
        `Proxy admin deployed, gasUsed: ${rec.gasUsed.toString()}, tx hash ${rec.transactionHash}, expected address:
         ${proxyAdmin.address}`
      );
      console.log(`CONTRACTS_TRANSPARENT_PROXY_ADMIN_ADDR=${proxyAdmin.address}`);
    }

    this.addresses.TransparentProxyAdmin = proxyAdmin.address;

    const tx = await proxyAdmin.transferOwnership(this.addresses.Governance);
    const receipt = await tx.wait();

    if (this.verbose) {
      console.log(
        `ProxyAdmin ownership transferred to Governance in tx
        ${receipt.transactionHash}, gas used: ${receipt.gasUsed.toString()}`
      );
    }
  }

  public async deployBridgehubImplementation(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const contractAddress = await this.deployViaCreate2(
      "Bridgehub",
      [await this.getL1ChainId(), this.addresses.Governance, getNumberFromEnv("CONTRACTS_MAX_NUMBER_OF_ZK_CHAINS")],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_BRIDGEHUB_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridgehub.BridgehubImplementation = contractAddress;
  }

  public async deployBridgehubProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const bridgehub = new Interface(hardhat.artifacts.readArtifactSync("Bridgehub").abi);

    const initCalldata = bridgehub.encodeFunctionData("initialize", [this.addresses.Governance]);

    const contractAddress = await this.deployViaCreate2(
      "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
      [this.addresses.Bridgehub.BridgehubImplementation, this.addresses.TransparentProxyAdmin, initCalldata],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_BRIDGEHUB_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridgehub.BridgehubProxy = contractAddress;
  }

  public async deployMessageRootImplementation(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const contractAddress = await this.deployViaCreate2(
      "MessageRoot",
      [this.addresses.Bridgehub.BridgehubProxy],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_MESSAGE_ROOT_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridgehub.MessageRootImplementation = contractAddress;
  }

  public async deployMessageRootProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const messageRoot = new Interface(hardhat.artifacts.readArtifactSync("MessageRoot").abi);

    const initCalldata = messageRoot.encodeFunctionData("initialize");

    const contractAddress = await this.deployViaCreate2(
      "TransparentUpgradeableProxy",
      [this.addresses.Bridgehub.MessageRootImplementation, this.addresses.TransparentProxyAdmin, initCalldata],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_MESSAGE_ROOT_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridgehub.MessageRootProxy = contractAddress;
  }

  public async deployChainTypeManagerImplementation(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    const contractAddress = await this.deployViaCreate2(
      "ChainTypeManager",
      [this.addresses.Bridgehub.BridgehubProxy],
      create2Salt,
      {
        ...ethTxOptions,
        gasLimit: 20_000_000,
      }
    );

    if (this.verbose) {
      console.log(`CONTRACTS_STATE_TRANSITION_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.StateTransitionImplementation = contractAddress;
  }

  public async deployChainTypeManagerProxy(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest,
    extraFacets?: FacetCut[]
  ) {
    const genesisBatchHash = getHashFromEnv("CONTRACTS_GENESIS_ROOT"); // TODO: confusing name
    const genesisRollupLeafIndex = getNumberFromEnv("CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX");
    const genesisBatchCommitment = getHashFromEnv("CONTRACTS_GENESIS_BATCH_COMMITMENT");
    const diamondCut = await this.initialZkSyncZKChainDiamondCut(extraFacets);
    const protocolVersion = packSemver(...unpackStringSemVer(process.env.CONTRACTS_GENESIS_PROTOCOL_SEMANTIC_VERSION));

    const chainTypeManager = new Interface(hardhat.artifacts.readArtifactSync("ChainTypeManager").abi);
    const forceDeploymentsData = await this.genesisForceDeploymentsData();
    const chainCreationParams = {
      genesisUpgrade: this.addresses.StateTransition.GenesisUpgrade,
      genesisBatchHash,
      genesisIndexRepeatedStorageChanges: genesisRollupLeafIndex,
      genesisBatchCommitment,
      diamondCut,
      forceDeploymentsData,
    };

    const initCalldata = chainTypeManager.encodeFunctionData("initialize", [
      {
        owner: this.addresses.Governance,
        validatorTimelock: this.addresses.ValidatorTimeLock,
        chainCreationParams,
        protocolVersion,
      },
    ]);

    const contractAddress = await this.deployViaCreate2(
      "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
      [
        this.addresses.StateTransition.StateTransitionImplementation,
        this.addresses.TransparentProxyAdmin,
        initCalldata,
      ],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`ChainTypeManagerProxy deployed, with protocol version: ${protocolVersion}`);
      console.log(`CONTRACTS_STATE_TRANSITION_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.StateTransitionProxy = contractAddress;
  }

  public async deployAdminFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const contractAddress = await this.deployViaCreate2(
      "AdminFacet",
      [await this.getL1ChainId(), ethers.constants.AddressZero],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_ADMIN_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.AdminFacet = contractAddress;
  }

  public async deployMailboxFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const eraChainId = getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID");
    const contractAddress = await this.deployViaCreate2(
      "MailboxFacet",
      [eraChainId, await this.getL1ChainId()],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`Mailbox deployed with era chain id: ${eraChainId}`);
      console.log(`CONTRACTS_MAILBOX_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.MailboxFacet = contractAddress;
  }

  public async deployExecutorFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const contractAddress = await this.deployViaCreate2(
      "ExecutorFacet",
      [await this.getL1ChainId()],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_EXECUTOR_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.ExecutorFacet = contractAddress;
  }

  public async deployGettersFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const contractAddress = await this.deployViaCreate2("GettersFacet", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_GETTERS_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.GettersFacet = contractAddress;
  }

  public async deployVerifier(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    let contractAddress: string;

    if (process.env.CHAIN_ETH_NETWORK === "mainnet") {
      contractAddress = await this.deployViaCreate2("Verifier", [], create2Salt, ethTxOptions);
    } else {
      contractAddress = await this.deployViaCreate2("TestnetVerifier", [], create2Salt, ethTxOptions);
    }

    if (this.verbose) {
      console.log(`CONTRACTS_VERIFIER_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.Verifier = contractAddress;
  }

  public async deployERC20BridgeImplementation(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest,
    dummy: boolean = false
  ) {
    const eraChainId = getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID");
    const contractAddress = await this.deployViaCreate2(
      dummy ? "DummyL1ERC20Bridge" : "L1ERC20Bridge",
      [
        this.addresses.Bridges.L1NullifierProxy,
        this.addresses.Bridges.SharedBridgeProxy,
        this.addresses.Bridges.NativeTokenVaultProxy,
        eraChainId,
      ],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_ERC20_BRIDGE_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.ERC20BridgeImplementation = contractAddress;
  }

  public async setParametersSharedBridge() {
    const sharedBridge = L1AssetRouterFactory.connect(this.addresses.Bridges.SharedBridgeProxy, this.deployWallet);
    const data1 = sharedBridge.interface.encodeFunctionData("setL1Erc20Bridge", [
      this.addresses.Bridges.ERC20BridgeProxy,
    ]);
    await this.executeUpgrade(this.addresses.Bridges.SharedBridgeProxy, 0, data1);
    if (this.verbose) {
      console.log("Shared bridge updated with ERC20Bridge address");
    }
  }

  public async executeDirectOrGovernance(
    useGovernance: boolean,
    contract: Contract,
    fname: string,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    fargs: any[],
    value: BigNumberish,
    overrides?: ethers.providers.TransactionRequest,
    printOperation: boolean = false
  ): Promise<ethers.ContractReceipt> {
    if (useGovernance) {
      const cdata = contract.interface.encodeFunctionData(fname, fargs);
      return this.executeUpgrade(contract.address, value, cdata, overrides, printOperation);
    } else {
      overrides = overrides || {};
      overrides.value = value;
      const tx: ethers.ContractTransaction = await contract[fname](...fargs, overrides);
      return await tx.wait();
    }
  }

  /// this should be only use for local testing
  public async executeUpgrade(
    targetAddress: string,
    value: BigNumberish,
    callData: string,
    ethTxOptions?: ethers.providers.TransactionRequest,
    printOperation: boolean = false
  ) {
    const governance = IGovernanceFactory.connect(this.addresses.Governance, this.deployWallet);
    const operation = {
      calls: [{ target: targetAddress, value: value, data: callData }],
      predecessor: ethers.constants.HashZero,
      salt: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
    };
    if (printOperation) {
      console.log("Operation:", operation);
      console.log(
        "Schedule operation: ",
        governance.interface.encodeFunctionData("scheduleTransparent", [operation, 0])
      );
      console.log(
        `Execute operation value: ${value}, calldata`,
        governance.interface.encodeFunctionData("execute", [operation])
      );
      return;
    }
    const scheduleTx = await governance.scheduleTransparent(operation, 0);
    await scheduleTx.wait();
    if (this.verbose) {
      console.log("Upgrade scheduled");
    }
    const executeTX = await governance.execute(operation, { ...ethTxOptions, value: value });
    const receipt = await executeTX.wait();
    if (this.verbose) {
      console.log(
        "Upgrade with target ",
        targetAddress,
        "executed: ",
        await governance.isOperationDone(await governance.hashOperation(operation))
      );
    }
    return receipt;
  }

  /// this should be only use for local testing
  public async executeUpgradeOnL2(
    chainId: string,
    targetAddress: string,
    gasPrice: BigNumberish,
    callData: string,
    l2GasLimit: BigNumberish,
    ethTxOptions?: ethers.providers.TransactionRequest,
    printOperation: boolean = false
  ) {
    const bridgehub = this.bridgehubContract(this.deployWallet);
    const value = await bridgehub.l2TransactionBaseCost(
      chainId,
      gasPrice,
      l2GasLimit,
      REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    );
    const baseTokenAddress = await bridgehub.baseToken(chainId);
    const ethIsBaseToken = baseTokenAddress == ADDRESS_ONE;
    if (!ethIsBaseToken) {
      const baseToken = TestnetERC20TokenFactory.connect(baseTokenAddress, this.deployWallet);
      await (await baseToken.transfer(this.addresses.Governance, value)).wait();
      await this.executeUpgrade(
        baseTokenAddress,
        0,
        baseToken.interface.encodeFunctionData("approve", [this.addresses.Bridges.SharedBridgeProxy, value])
      );
    }
    const l1Calldata = bridgehub.interface.encodeFunctionData("requestL2TransactionDirect", [
      {
        chainId,
        l2Contract: targetAddress,
        mintValue: value,
        l2Value: 0,
        l2Calldata: callData,
        l2GasLimit: l2GasLimit,
        l2GasPerPubdataByteLimit: SYSTEM_CONFIG.requiredL2GasPricePerPubdata,
        factoryDeps: [],
        refundRecipient: this.deployWallet.address,
      },
    ]);
    const receipt = await this.executeUpgrade(
      this.addresses.Bridgehub.BridgehubProxy,
      ethIsBaseToken ? value : 0,
      l1Calldata,
      {
        ...ethTxOptions,
        gasPrice,
      },
      printOperation
    );
    return receipt;
  }

  // used for testing, mimics original deployment process.
  // we don't use the real implementation, as we need the address to be independent
  public async deployERC20BridgeProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const initCalldata = new Interface(hardhat.artifacts.readArtifactSync("L1ERC20Bridge").abi).encodeFunctionData(
      "initialize"
    );
    const contractAddress = await this.deployViaCreate2(
      "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
      [this.addresses.Bridges.ERC20BridgeImplementation, this.addresses.TransparentProxyAdmin, initCalldata],
      create2Salt,
      ethTxOptions
    );
    if (this.verbose) {
      console.log(`CONTRACTS_L1_ERC20_BRIDGE_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.ERC20BridgeProxy = contractAddress;
  }

  public async deployL1NullifierImplementation(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    // const tokens = getTokens();
    // const l1WethToken = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;
    const eraChainId = getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID");
    const eraDiamondProxy = getAddressFromEnv("CONTRACTS_ERA_DIAMOND_PROXY_ADDR");
    const contractName = isCurrentNetworkLocal() ? "L1NullifierDev" : "L1Nullifier";
    const contractAddress = await this.deployViaCreate2(
      contractName,
      [this.addresses.Bridgehub.BridgehubProxy, eraChainId, eraDiamondProxy],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_NULLIFIER_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.L1NullifierImplementation = contractAddress;
  }

  public async deployL1NullifierProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const initCalldata = new Interface(hardhat.artifacts.readArtifactSync("L1Nullifier").abi).encodeFunctionData(
      "initialize",
      [this.addresses.Governance, 1, 1, 1, 0]
    );
    const contractAddress = await this.deployViaCreate2(
      "TransparentUpgradeableProxy",
      [this.addresses.Bridges.L1NullifierImplementation, this.addresses.TransparentProxyAdmin, initCalldata],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_NULLIFIER_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.L1NullifierProxy = contractAddress;
  }

  public async deploySharedBridgeImplementation(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    const tokens = getTokens();
    const l1WethToken = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;
    const eraChainId = getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID");
    const eraDiamondProxy = getAddressFromEnv("CONTRACTS_ERA_DIAMOND_PROXY_ADDR");
    const contractAddress = await this.deployViaCreate2(
      "L1AssetRouter",
      [
        l1WethToken,
        this.addresses.Bridgehub.BridgehubProxy,
        this.addresses.Bridges.L1NullifierProxy,
        eraChainId,
        eraDiamondProxy,
      ],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`With era chain id ${eraChainId} and era diamond proxy ${eraDiamondProxy}`);
      console.log(`CONTRACTS_L1_SHARED_BRIDGE_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.SharedBridgeImplementation = contractAddress;
  }

  public async deploySharedBridgeProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const initCalldata = new Interface(hardhat.artifacts.readArtifactSync("L1AssetRouter").abi).encodeFunctionData(
      "initialize",
      [this.addresses.Governance]
    );
    const contractAddress = await this.deployViaCreate2(
      "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
      [this.addresses.Bridges.SharedBridgeImplementation, this.addresses.TransparentProxyAdmin, initCalldata],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_SHARED_BRIDGE_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.SharedBridgeProxy = contractAddress;
  }

  public async deployBridgedStandardERC20Implementation(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    const contractAddress = await this.deployViaCreate2("BridgedStandardERC20", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      // console.log(`With era chain id ${eraChainId}`);
      console.log(`CONTRACTS_L1_BRIDGED_STANDARD_ERC20_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.BridgedStandardERC20Implementation = contractAddress;
  }

  public async deployBridgedTokenBeacon(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    /// Note we cannot use create2 as the deployer is the owner.
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractFactory = await hardhat.ethers.getContractFactory(
      "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon",
      {
        signer: this.deployWallet,
      }
    );
    const beacon = await contractFactory.deploy(
      ...[this.addresses.Bridges.BridgedStandardERC20Implementation, ethTxOptions]
    );
    const rec = await beacon.deployTransaction.wait();

    if (this.verbose) {
      console.log("Beacon deployed with tx hash", rec.transactionHash);
      console.log(`CONTRACTS_L1_BRIDGED_TOKEN_BEACON_ADDR=${beacon.address}`);
    }

    this.addresses.Bridges.BridgedTokenBeacon = beacon.address;

    await beacon.transferOwnership(this.addresses.Governance);
  }

  public async deployNativeTokenVaultImplementation(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    const tokens = getTokens();
    const l1WethToken = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;
    const contractAddress = await this.deployViaCreate2(
      "L1NativeTokenVault",
      [l1WethToken, this.addresses.Bridges.SharedBridgeProxy, this.addresses.Bridges.L1NullifierProxy],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      // console.log(`With era chain id ${eraChainId}`);
      console.log(`CONTRACTS_L1_NATIVE_TOKEN_VAULT_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.NativeTokenVaultImplementation = contractAddress;
  }

  public async deployNativeTokenVaultProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const initCalldata = new Interface(hardhat.artifacts.readArtifactSync("L1NativeTokenVault").abi).encodeFunctionData(
      "initialize",
      [this.addresses.Governance, this.addresses.Bridges.BridgedTokenBeacon]
    );
    const contractAddress = await this.deployViaCreate2(
      "TransparentUpgradeableProxy",
      [this.addresses.Bridges.NativeTokenVaultImplementation, this.addresses.TransparentProxyAdmin, initCalldata],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_NATIVE_TOKEN_VAULT_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.NativeTokenVaultProxy = contractAddress;

    const nullifier = this.l1NullifierContract(this.deployWallet);
    const assetRouter = this.defaultSharedBridge(this.deployWallet);
    const ntv = this.nativeTokenVault(this.deployWallet);

    const data = await assetRouter.interface.encodeFunctionData("setNativeTokenVault", [
      this.addresses.Bridges.NativeTokenVaultProxy,
    ]);
    await this.executeUpgrade(this.addresses.Bridges.SharedBridgeProxy, 0, data);
    if (this.verbose) {
      console.log("Native token vault set in shared bridge");
    }

    const data2 = await nullifier.interface.encodeFunctionData("setL1NativeTokenVault", [
      this.addresses.Bridges.NativeTokenVaultProxy,
    ]);
    await this.executeUpgrade(this.addresses.Bridges.L1NullifierProxy, 0, data2);
    if (this.verbose) {
      console.log("Native token vault set in nullifier");
    }

    const data3 = await nullifier.interface.encodeFunctionData("setL1AssetRouter", [
      this.addresses.Bridges.SharedBridgeProxy,
    ]);
    await this.executeUpgrade(this.addresses.Bridges.L1NullifierProxy, 0, data3);
    if (this.verbose) {
      console.log("Asset router set in nullifier");
    }

    await (await this.nativeTokenVault(this.deployWallet).registerEthToken()).wait();

    await ntv.registerEthToken();
  }

  public async deployCTMDeploymentTrackerImplementation(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    const contractAddress = await this.deployViaCreate2(
      "CTMDeploymentTracker",
      [this.addresses.Bridgehub.BridgehubProxy, this.addresses.Bridges.SharedBridgeProxy],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_CTM_DEPLOYMENT_TRACKER_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridgehub.CTMDeploymentTrackerImplementation = contractAddress;
  }

  public async deployCTMDeploymentTrackerProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const initCalldata = new Interface(
      hardhat.artifacts.readArtifactSync("CTMDeploymentTracker").abi
    ).encodeFunctionData("initialize", [this.addresses.Governance]);
    const contractAddress = await this.deployViaCreate2(
      "TransparentUpgradeableProxy",
      [this.addresses.Bridgehub.CTMDeploymentTrackerImplementation, this.addresses.TransparentProxyAdmin, initCalldata],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_CTM_DEPLOYMENT_TRACKER_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridgehub.CTMDeploymentTrackerProxy = contractAddress;

    // const bridgehub = this.bridgehubContract(this.deployWallet);
    // const data0 = bridgehub.interface.encodeFunctionData("setCTMDeployer", [
    //   this.addresses.Bridgehub.CTMDeploymentTrackerProxy,
    // ]);
    // await this.executeUpgrade(this.addresses.Bridgehub.BridgehubProxy, 0, data0);
    // if (this.verbose) {
    //   console.log("CTM DT registered in Bridgehub");
    // }
  }

  public async sharedBridgeSetEraPostUpgradeFirstBatch() {
    const sharedBridge = L1AssetRouterFactory.connect(this.addresses.Bridges.SharedBridgeProxy, this.deployWallet);
    const storageSwitch = getNumberFromEnv("CONTRACTS_SHARED_BRIDGE_UPGRADE_STORAGE_SWITCH");
    const tx = await sharedBridge.setEraPostUpgradeFirstBatch(storageSwitch);
    const receipt = await tx.wait();
    if (this.verbose) {
      console.log(`Era first post upgrade batch set, gas used: ${receipt.gasUsed.toString()}`);
    }
  }

  public async registerAddresses() {
    const bridgehub = this.bridgehubContract(this.deployWallet);

    const upgradeData1 = await bridgehub.interface.encodeFunctionData("setAddresses", [
      this.addresses.Bridges.SharedBridgeProxy,
      this.addresses.Bridgehub.CTMDeploymentTrackerProxy,
      this.addresses.Bridgehub.MessageRootProxy,
    ]);
    await this.executeUpgrade(this.addresses.Bridgehub.BridgehubProxy, 0, upgradeData1);
    if (this.verbose) {
      console.log("Shared bridge was registered in Bridgehub");
    }
  }

  public async registerTokenBridgehub(tokenAddress: string, useGovernance: boolean = false) {
    const bridgehub = this.bridgehubContract(this.deployWallet);
    const baseTokenAssetId = encodeNTVAssetId(this.l1ChainId, tokenAddress);
    const receipt = await this.executeDirectOrGovernance(
      useGovernance,
      bridgehub,
      "addTokenAssetId",
      [baseTokenAssetId],
      0
    );

    if (this.verbose) {
      console.log(`Token ${tokenAddress} was registered, gas used: ${receipt.gasUsed.toString()}`);
    }
  }

  public async registerTokenInNativeTokenVault(token: string) {
    const nativeTokenVault = this.nativeTokenVault(this.deployWallet);

    const data = nativeTokenVault.interface.encodeFunctionData("registerToken", [token]);
    await this.executeUpgrade(this.addresses.Bridges.NativeTokenVaultProxy, 0, data);
    if (this.verbose) {
      console.log("Native token vault registered with token", token);
    }
  }

  public async deployStateTransitionDiamondInit(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    const contractAddress = await this.deployViaCreate2("DiamondInit", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_DIAMOND_INIT_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.DiamondInit = contractAddress;
  }

  public async deployDefaultUpgrade(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const contractAddress = await this.deployViaCreate2("DefaultUpgrade", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_DEFAULT_UPGRADE_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.DefaultUpgrade = contractAddress;
  }

  public async deployZKChainsUpgrade(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const contractAddress = await this.deployViaCreate2("UpgradeZKChains", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_ZK_CHAIN_UPGRADE_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.DefaultUpgrade = contractAddress;
  }

  public async deployGenesisUpgrade(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const contractAddress = await this.deployViaCreate2("L1GenesisUpgrade", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_GENESIS_UPGRADE_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.GenesisUpgrade = contractAddress;
  }

  public async deployBridgehubContract(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployBridgehubImplementation(create2Salt, { gasPrice, nonce });
    await this.deployBridgehubProxy(create2Salt, { gasPrice });
    await this.deployMessageRootImplementation(create2Salt, { gasPrice });
    await this.deployMessageRootProxy(create2Salt, { gasPrice });
  }

  public async deployChainTypeManagerContract(
    create2Salt: string,
    extraFacets?: FacetCut[],
    gasPrice?: BigNumberish,
    nonce?
  ) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();
    await this.deployStateTransitionDiamondFacets(create2Salt, gasPrice, nonce);
    await this.deployChainTypeManagerImplementation(create2Salt, { gasPrice });
    await this.deployChainTypeManagerProxy(create2Salt, { gasPrice }, extraFacets);
    await this.registerChainTypeManager();
  }

  public async deployStateTransitionDiamondFacets(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployExecutorFacet(create2Salt, { gasPrice, nonce: nonce });
    await this.deployAdminFacet(create2Salt, { gasPrice, nonce: nonce + 1 });
    await this.deployMailboxFacet(create2Salt, { gasPrice, nonce: nonce + 2 });
    await this.deployGettersFacet(create2Salt, { gasPrice, nonce: nonce + 3 });
    await this.deployStateTransitionDiamondInit(create2Salt, { gasPrice, nonce: nonce + 4 });
  }

  public async registerChainTypeManager() {
    const bridgehub = this.bridgehubContract(this.deployWallet);

    if (!(await bridgehub.chainTypeManagerIsRegistered(this.addresses.StateTransition.StateTransitionProxy))) {
      const upgradeData = bridgehub.interface.encodeFunctionData("addChainTypeManager", [
        this.addresses.StateTransition.StateTransitionProxy,
      ]);

      let receipt1;
      if (!this.isZkMode()) {
        receipt1 = await this.executeUpgrade(this.addresses.Bridgehub.BridgehubProxy, 0, upgradeData);
        if (this.verbose) {
          console.log(`StateTransition System registered, gas used: ${receipt1.gasUsed.toString()}`);
        }

        const ctmDeploymentTracker = this.ctmDeploymentTracker(this.deployWallet);

        const l1AssetRouter = this.defaultSharedBridge(this.deployWallet);
        const whitelistData = l1AssetRouter.interface.encodeFunctionData("setAssetDeploymentTracker", [
          ethers.utils.hexZeroPad(this.addresses.StateTransition.StateTransitionProxy, 32),
          ctmDeploymentTracker.address,
        ]);
        const receipt2 = await this.executeUpgrade(l1AssetRouter.address, 0, whitelistData);
        if (this.verbose) {
          console.log("CTM deployment tracker whitelisted in L1 Shared Bridge", receipt2.gasUsed.toString());
          console.log(
            `CONTRACTS_CTM_ASSET_INFO=${await bridgehub.ctmAssetId(this.addresses.StateTransition.StateTransitionProxy)}`
          );
        }

        const data1 = ctmDeploymentTracker.interface.encodeFunctionData("registerCTMAssetOnL1", [
          this.addresses.StateTransition.StateTransitionProxy,
        ]);
        const receipt3 = await this.executeUpgrade(this.addresses.Bridgehub.CTMDeploymentTrackerProxy, 0, data1);
        if (this.verbose) {
          console.log(
            "CTM asset registered in L1 Shared Bridge via CTM Deployment Tracker",
            receipt3.gasUsed.toString()
          );
          console.log(
            `CONTRACTS_CTM_ASSET_INFO=${await bridgehub.ctmAssetId(this.addresses.StateTransition.StateTransitionProxy)}`
          );
        }
      } else {
        console.log(`CONTRACTS_CTM_ASSET_INFO=${getHashFromEnv("CONTRACTS_CTM_ASSET_INFO")}`);
      }
    }
  }

  public async registerSettlementLayer() {
    const bridgehub = this.bridgehubContract(this.deployWallet);
    const calldata = bridgehub.interface.encodeFunctionData("registerSettlementLayer", [this.chainId, true]);
    await this.executeUpgrade(this.addresses.Bridgehub.BridgehubProxy, 0, calldata);
    if (this.verbose) {
      console.log("Gateway registered");
    }
  }

  // Main function to move the current chain (that is hooked to l1), on top of the syncLayer chain.
  public async moveChainToGateway(gatewayChainId: string, gasPrice: BigNumberish) {
    const protocolVersion = packSemver(...unpackStringSemVer(process.env.CONTRACTS_GENESIS_PROTOCOL_SEMANTIC_VERSION));
    const chainData = ethers.utils.defaultAbiCoder.encode(["uint256"], [protocolVersion]);
    const bridgehub = this.bridgehubContract(this.deployWallet);
    // Just some large gas limit that should always be enough
    const l2GasLimit = ethers.BigNumber.from(72_000_000);
    const expectedCost = (
      await bridgehub.l2TransactionBaseCost(gatewayChainId, gasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA)
    ).mul(5);

    // We are creating the new DiamondProxy for our chain, to be deployed on top of sync Layer.
    const newAdmin = this.deployWallet.address;
    const diamondCutData = await this.initialZkSyncZKChainDiamondCut();
    const initialDiamondCut = new ethers.utils.AbiCoder().encode([DIAMOND_CUT_DATA_ABI_STRING], [diamondCutData]);

    const ctmData = new ethers.utils.AbiCoder().encode(["uint256", "bytes"], [newAdmin, initialDiamondCut]);
    const bridgehubData = new ethers.utils.AbiCoder().encode(
      [BRIDGEHUB_CTM_ASSET_DATA_ABI_STRING],
      [[this.chainId, ctmData, chainData]]
    );

    // console.log("bridgehubData", bridgehubData)
    // console.log("this.addresses.ChainAssetInfo", this.addresses.ChainAssetInfo)

    // The ctmAssetIFromChainId gives us a unique 'asset' identifier for a given chain.
    const chainAssetId = await bridgehub.ctmAssetIdFromChainId(this.chainId);
    if (this.verbose) {
      console.log("Chain asset id is: ", chainAssetId);
      console.log(`CONTRACTS_CTM_ASSET_INFO=${chainAssetId}`);
    }

    let sharedBridgeData = ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "bytes"],

      [chainAssetId, bridgehubData]
    );
    // The 0x01 is the encoding for the L1AssetRouter.
    sharedBridgeData = "0x01" + sharedBridgeData.slice(2);

    // And now we 'transfer' the chain through the bridge (it behaves like a 'regular' asset, where we 'freeze' it in L1
    // and then create on SyncLayer). You can see these methods in Admin.sol (part of DiamondProxy).
    const receipt = await this.executeChainAdminMulticall([
      {
        target: bridgehub.address,
        data: bridgehub.interface.encodeFunctionData("requestL2TransactionTwoBridges", [
          // These arguments must match L2TransactionRequestTwoBridgesOuter struct.
          {
            chainId: gatewayChainId,
            mintValue: expectedCost,
            l2Value: 0,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            refundRecipient: await this.deployWallet.getAddress(),
            secondBridgeAddress: this.addresses.Bridges.SharedBridgeProxy,
            secondBridgeValue: 0,
            secondBridgeCalldata: sharedBridgeData,
          },
        ]),
        value: expectedCost,
      },
    ]);

    return receipt;
  }

  public async finishMoveChainToL1(synclayerChainId: number) {
    const nullifier = this.l1NullifierContract(this.deployWallet);
    // const baseTokenAmount = ethers.utils.parseEther("1");
    // const chainData = new ethers.utils.AbiCoder().encode(["uint256", "bytes"], [ADDRESS_ONE, "0x"]); // todo
    // const bridgehubData = new ethers.utils.AbiCoder().encode(["uint256", "bytes"], [this.chainId, chainData]);
    // console.log("bridgehubData", bridgehubData)
    // console.log("this.addresses.ChainAssetInfo", this.addresses.ChainAssetInfo)
    // const sharedBridgeData = ethers.utils.defaultAbiCoder.encode(
    //   ["bytes32", "bytes"],

    //   [await bridgehub.ctmAssetInfoFromChainId(this.chainId), bridgehubData]
    // );
    const l2BatchNumber = 1;
    const l2MsgIndex = 1;
    const l2TxNumberInBatch = 1;
    const message = ethers.utils.defaultAbiCoder.encode(["bytes32", "bytes"], []);
    const merkleProof = ["0x00"];
    const tx = await nullifier.finalizeWithdrawal(
      synclayerChainId,
      l2BatchNumber,
      l2MsgIndex,
      l2TxNumberInBatch,
      message,
      merkleProof
    );
    const receipt = await tx.wait();
    if (this.verbose) {
      console.log("Chain move to L1 finished", receipt.gasUsed.toString());
    }
  }

  public async registerZKChain(
    baseTokenAssetId: string,
    validiumMode: boolean,
    extraFacets?: FacetCut[],
    gasPrice?: BigNumberish,
    compareDiamondCutHash: boolean = false,
    nonce?,
    predefinedChainId?: string,
    useGovernance: boolean = false,
    l2LegacySharedBridge: boolean = false
  ) {
    const txOptions = this.isZkMode() ? {} : { gasLimit: 10_000_000 };

    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    const bridgehub = this.bridgehubContract(this.deployWallet);
    const chainTypeManager = this.chainTypeManagerContract(this.deployWallet);
    const ntv = this.nativeTokenVault(this.deployWallet);
    const baseTokenAddress = await ntv.tokenAddress(baseTokenAssetId);

    const inputChainId = predefinedChainId || getNumberFromEnv("CHAIN_ETH_ZKSYNC_NETWORK_ID");
    const alreadyRegisteredInCTM = (await chainTypeManager.getZKChain(inputChainId)) != ethers.constants.AddressZero;

    if (l2LegacySharedBridge) {
      if (this.verbose) {
        console.log("Setting L2 legacy shared bridge in L1Nullifier");
      }
      await this.setL2LegacySharedBridgeInL1Nullifier(inputChainId);
      nonce++;
    }

    const admin = process.env.CHAIN_ADMIN_ADDRESS || this.ownerAddress;
    const diamondCutData = await this.initialZkSyncZKChainDiamondCut(extraFacets, compareDiamondCutHash);
    const initialDiamondCut = new ethers.utils.AbiCoder().encode([DIAMOND_CUT_DATA_ABI_STRING], [diamondCutData]);
    const forceDeploymentsData = await this.genesisForceDeploymentsData();
    const initData = ethers.utils.defaultAbiCoder.encode(["bytes", "bytes"], [initialDiamondCut, forceDeploymentsData]);
    let factoryDeps = [];
    if (process.env.CHAIN_ETH_NETWORK != "hardhat") {
      factoryDeps = [
        L2_STANDARD_ERC20_PROXY_FACTORY.bytecode,
        L2_STANDARD_ERC20_IMPLEMENTATION.bytecode,
        L2_STANDARD_TOKEN_PROXY.bytecode,
      ];
    }
    // note the factory deps are provided at genesis
    const receipt = await this.executeDirectOrGovernance(
      useGovernance,
      bridgehub,
      "createNewChain",
      [
        inputChainId,
        this.addresses.StateTransition.StateTransitionProxy,
        baseTokenAssetId,
        Date.now(),
        admin,
        initData,
        factoryDeps,
      ],
      0,
      {
        gasPrice,
        ...txOptions,
      }
    );
    const chainId = receipt.logs.find((log) => log.topics[0] == bridgehub.interface.getEventTopic("NewChain"))
      .topics[1];

    nonce++;
    if (useGovernance) {
      // deploying through governance requires two transactions
      nonce++;
    }

    this.addresses.BaseToken = baseTokenAddress;
    this.addresses.BaseTokenAssetId = baseTokenAssetId;

    if (this.verbose) {
      console.log(`ZK chain registered, gas used: ${receipt.gasUsed.toString()} and ${receipt.gasUsed.toString()}`);
      console.log(`ZK chain registration tx hash: ${receipt.transactionHash}`);

      console.log(`CHAIN_ETH_ZKSYNC_NETWORK_ID=${parseInt(chainId, 16)}`);
      console.log(
        `CONTRACTS_CTM_ASSET_INFO=${await bridgehub.ctmAssetId(this.addresses.StateTransition.StateTransitionProxy)}`
      );
      console.log(`CONTRACTS_BASE_TOKEN_ADDR=${baseTokenAddress}`);
    }

    if (!alreadyRegisteredInCTM) {
      const diamondProxyAddress =
        "0x" +
        receipt.logs
          .find((log) => log.topics[0] == chainTypeManager.interface.getEventTopic("NewZKChain"))
          .topics[2].slice(26);
      this.addresses.StateTransition.DiamondProxy = diamondProxyAddress;
      if (this.verbose) {
        console.log(`CONTRACTS_DIAMOND_PROXY_ADDR=${diamondProxyAddress}`);
      }
    }
    const intChainId = parseInt(chainId, 16);
    this.chainId = intChainId;

    const validatorOneAddress = getAddressFromEnv("ETH_SENDER_SENDER_OPERATOR_COMMIT_ETH_ADDR");
    const validatorTwoAddress = getAddressFromEnv("ETH_SENDER_SENDER_OPERATOR_BLOBS_ETH_ADDR");
    const validatorTimelock = this.validatorTimelock(this.deployWallet);
    const txRegisterValidator = await validatorTimelock.addValidator(chainId, validatorOneAddress, {
      gasPrice,
      nonce,
      ...txOptions,
    });
    const receiptRegisterValidator = await txRegisterValidator.wait();
    if (this.verbose) {
      console.log(
        `Validator registered, gas used: ${receiptRegisterValidator.gasUsed.toString()}, tx hash:
         ${txRegisterValidator.hash}`
      );
    }

    nonce++;

    const tx3 = await validatorTimelock.addValidator(chainId, validatorTwoAddress, {
      gasPrice,
      nonce,
      ...txOptions,
    });
    const receipt3 = await tx3.wait();
    if (this.verbose) {
      console.log(`Validator 2 registered, gas used: ${receipt3.gasUsed.toString()}`);
    }

    const diamondProxy = this.stateTransitionContract(this.deployWallet);
    // if we are using governance, the deployer will not be the admin, so we can't call the diamond proxy directly
    if (admin == this.deployWallet.address) {
      const tx4 = await diamondProxy.setTokenMultiplier(1, 1);
      const receipt4 = await tx4.wait();
      if (this.verbose) {
        console.log(`BaseTokenMultiplier set, gas used: ${receipt4.gasUsed.toString()}`);
      }

      if (validiumMode) {
        const tx5 = await diamondProxy.setPubdataPricingMode(PubdataPricingMode.Validium);
        const receipt5 = await tx5.wait();
        if (this.verbose) {
          console.log(`Validium mode set, gas used: ${receipt5.gasUsed.toString()}`);
        }
      }
    } else {
      console.warn(
        "BaseTokenMultiplier and Validium mode can't be set through the governance, please set it separately, using the admin account"
      );
    }

    if (l2LegacySharedBridge) {
      await this.deployL2LegacySharedBridge(inputChainId, gasPrice);
    }
  }

  public async setL2LegacySharedBridgeInL1Nullifier(inputChainId: string) {
    const l1Nullifier = L1NullifierDevFactory.connect(this.addresses.Bridges.L1NullifierProxy, this.deployWallet);
    const l1SharedBridge = this.defaultSharedBridge(this.deployWallet);

    if (isCurrentNetworkLocal()) {
      const l2SharedBridgeImplementationBytecode = L2_SHARED_BRIDGE_IMPLEMENTATION.bytecode;

      const l2SharedBridgeImplAddress = computeL2Create2Address(
        this.deployWallet.address,
        l2SharedBridgeImplementationBytecode,
        "0x",
        ethers.constants.HashZero
      );

      const l2GovernorAddress = applyL1ToL2Alias(this.addresses.Governance);

      const l2SharedBridgeInterface = new Interface(L2_SHARED_BRIDGE_IMPLEMENTATION.abi);
      const proxyInitializationParams = l2SharedBridgeInterface.encodeFunctionData("initialize", [
        l1SharedBridge.address,
        hashL2Bytecode(L2_STANDARD_TOKEN_PROXY.bytecode),
        l2GovernorAddress,
      ]);

      const l2SharedBridgeProxyConstructorData = ethers.utils.arrayify(
        new ethers.utils.AbiCoder().encode(
          ["address", "address", "bytes"],
          [l2SharedBridgeImplAddress, l2GovernorAddress, proxyInitializationParams]
        )
      );

      /// compute L2SharedBridgeProxy address
      const l2SharedBridgeProxyAddress = computeL2Create2Address(
        this.deployWallet.address,
        L2_SHARED_BRIDGE_PROXY.bytecode,
        l2SharedBridgeProxyConstructorData,
        ethers.constants.HashZero
      );

      const tx = await l1Nullifier.setL2LegacySharedBridge(inputChainId, l2SharedBridgeProxyAddress);
      const receipt8 = await tx.wait();
      if (this.verbose) {
        console.log(`L2 legacy shared bridge set in L1 Nullifier, gas used: ${receipt8.gasUsed.toString()}`);
      }
    }
  }

  public async deployL2LegacySharedBridge(inputChainId: string, gasPrice: BigNumberish) {
    if (this.verbose) {
      console.log("Deploying L2 legacy shared bridge");
    }
    await this.deploySharedBridgeImplOnL2ThroughL1(inputChainId, gasPrice);
    await this.deploySharedBridgeProxyOnL2ThroughL1(inputChainId, gasPrice);
  }

  public async deploySharedBridgeImplOnL2ThroughL1(chainId: string, gasPrice: BigNumberish) {
    if (this.verbose) {
      console.log("Deploying L2SharedBridge Implementation");
    }
    const eraChainId = getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID");

    const l2SharedBridgeImplementationBytecode = L2_SHARED_BRIDGE_IMPLEMENTATION.bytecode;
    // localLegacyBridgeTesting
    //   ? L2_DEV_SHARED_BRIDGE_IMPLEMENTATION.bytecode
    //   : L2_SHARED_BRIDGE_IMPLEMENTATION.bytecode;
    if (!l2SharedBridgeImplementationBytecode) {
      throw new Error("l2SharedBridgeImplementationBytecode not found");
    }

    if (this.verbose) {
      console.log("l2SharedBridgeImplementationBytecode loaded");

      console.log("Computing L2SharedBridge Implementation Address");
    }

    const l2SharedBridgeImplAddress = computeL2Create2Address(
      this.deployWallet.address,
      l2SharedBridgeImplementationBytecode,
      "0x",
      ethers.constants.HashZero
    );
    this.addresses.Bridges.L2LegacySharedBridgeImplementation = l2SharedBridgeImplAddress;

    if (this.verbose) {
      console.log(`L2SharedBridge Implementation Address: ${l2SharedBridgeImplAddress}`);

      console.log("Deploying L2SharedBridge Implementation");
    }
    // TODO: request from API how many L2 gas needs for the transaction.
    const tx2 = await create2DeployFromL1(
      chainId,
      this.deployWallet,
      l2SharedBridgeImplementationBytecode,
      ethers.utils.defaultAbiCoder.encode(["uint256"], [eraChainId]),
      ethers.constants.HashZero,
      priorityTxMaxGasLimit,
      gasPrice,
      [L2_STANDARD_TOKEN_PROXY.bytecode],
      this.addresses.Bridgehub.BridgehubProxy,
      this.addresses.Bridges.SharedBridgeProxy
    );
    await tx2.wait();

    if (this.verbose) {
      console.log("Deployed L2SharedBridge Implementation");
      console.log(`CONTRACTS_L2_LEGACY_SHARED_BRIDGE_IMPL_ADDR=${l2SharedBridgeImplAddress}`);
    }
  }

  public async deploySharedBridgeProxyOnL2ThroughL1(chainId: string, gasPrice: BigNumberish) {
    const l1SharedBridge = this.defaultSharedBridge(this.deployWallet);
    if (this.verbose) {
      console.log("Deploying L2SharedBridge Proxy");
    }
    const l2GovernorAddress = applyL1ToL2Alias(this.addresses.Governance);

    const l2SharedBridgeInterface = new Interface(L2_SHARED_BRIDGE_IMPLEMENTATION.abi);
    const proxyInitializationParams = l2SharedBridgeInterface.encodeFunctionData("initialize", [
      l1SharedBridge.address,
      hashL2Bytecode(L2_STANDARD_TOKEN_PROXY.bytecode),
      l2GovernorAddress,
    ]);

    /// prepare constructor data
    const l2SharedBridgeProxyConstructorData = ethers.utils.arrayify(
      new ethers.utils.AbiCoder().encode(
        ["address", "address", "bytes"],
        [this.addresses.Bridges.L2LegacySharedBridgeImplementation, l2GovernorAddress, proxyInitializationParams]
      )
    );

    /// compute L2SharedBridgeProxy address
    const l2SharedBridgeProxyAddress = computeL2Create2Address(
      this.deployWallet.address,
      L2_SHARED_BRIDGE_PROXY.bytecode,
      l2SharedBridgeProxyConstructorData,
      ethers.constants.HashZero
    );
    this.addresses.Bridges.L2LegacySharedBridgeProxy = l2SharedBridgeProxyAddress;

    /// deploy L2SharedBridgeProxy
    // TODO: request from API how many L2 gas needs for the transaction.
    const tx3 = await create2DeployFromL1(
      chainId,
      this.deployWallet,
      L2_SHARED_BRIDGE_PROXY.bytecode,
      l2SharedBridgeProxyConstructorData,
      ethers.constants.HashZero,
      priorityTxMaxGasLimit,
      gasPrice,
      undefined,
      this.addresses.Bridgehub.BridgehubProxy,
      this.addresses.Bridges.SharedBridgeProxy
    );
    await tx3.wait();
    if (this.verbose) {
      console.log(`CONTRACTS_L2_LEGACY_SHARED_BRIDGE_ADDR=${l2SharedBridgeProxyAddress}`);
    }
  }

  public async executeChainAdminMulticall(calls: ChainAdminCall[], requireSuccess: boolean = true) {
    const chainAdmin = ChainAdminFactory.connect(this.addresses.ChainAdmin, this.deployWallet);

    const totalValue = calls.reduce((acc, call) => acc.add(call.value), ethers.BigNumber.from(0));

    const multicallTx = await chainAdmin.multicall(calls, requireSuccess, { value: totalValue });
    return await multicallTx.wait();
  }

  public async setTokenMultiplierSetterAddress(tokenMultiplierSetterAddress: string) {
    const chainAdmin = ChainAdminFactory.connect(this.addresses.ChainAdmin, this.deployWallet);

    const receipt = await (await chainAdmin.setTokenMultiplierSetter(tokenMultiplierSetterAddress)).wait();
    if (this.verbose) {
      console.log(
        `Token multiplier setter set as ${tokenMultiplierSetterAddress}, gas used: ${receipt.gasUsed.toString()}`
      );
    }
  }

  public async transferAdminFromDeployerToChainAdmin() {
    const ctm = this.chainTypeManagerContract(this.deployWallet);
    const diamondProxyAddress = await ctm.getZKChain(this.chainId);
    const zkChain = IZKChainFactory.connect(diamondProxyAddress, this.deployWallet);

    const receipt = await (await zkChain.setPendingAdmin(this.addresses.ChainAdmin)).wait();
    if (this.verbose) {
      console.log(`ChainAdmin set as pending admin, gas used: ${receipt.gasUsed.toString()}`);
    }

    const acceptAdminData = zkChain.interface.encodeFunctionData("acceptAdmin");
    await this.executeChainAdminMulticall([
      {
        target: zkChain.address,
        value: 0,
        data: acceptAdminData,
      },
    ]);

    if (this.verbose) {
      console.log("Pending admin successfully accepted");
    }
  }

  public async deploySharedBridgeContracts(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployL1NullifierImplementation(create2Salt, { gasPrice, nonce: nonce });
    await this.deployL1NullifierProxy(create2Salt, { gasPrice, nonce: nonce + 1 });

    nonce = nonce + 2;
    await this.deploySharedBridgeImplementation(create2Salt, { gasPrice, nonce: nonce });
    await this.deploySharedBridgeProxy(create2Salt, { gasPrice, nonce: nonce + 1 });
    nonce = nonce + 2;
    await this.deployBridgedStandardERC20Implementation(create2Salt, { gasPrice, nonce: nonce });
    await this.deployBridgedTokenBeacon(create2Salt, { gasPrice, nonce: nonce + 1 });
    await this.deployNativeTokenVaultImplementation(create2Salt, { gasPrice, nonce: nonce + 3 });
    await this.deployNativeTokenVaultProxy(create2Salt, { gasPrice });
    await this.deployCTMDeploymentTrackerImplementation(create2Salt, { gasPrice });
    await this.deployCTMDeploymentTrackerProxy(create2Salt, { gasPrice });
    await this.registerAddresses();
  }

  public async deployValidatorTimelock(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const executionDelay = getNumberFromEnv("CONTRACTS_VALIDATOR_TIMELOCK_EXECUTION_DELAY");
    const contractAddress = await this.deployViaCreate2(
      "ValidatorTimelock",
      [this.ownerAddress, executionDelay],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_VALIDATOR_TIMELOCK_ADDR=${contractAddress}`);
    }
    this.addresses.ValidatorTimeLock = contractAddress;
  }

  public async setChainTypeManagerInValidatorTimelock(ethTxOptions: ethers.providers.TransactionRequest) {
    const validatorTimelock = this.validatorTimelock(this.deployWallet);
    const tx = await validatorTimelock.setChainTypeManager(
      this.addresses.StateTransition.StateTransitionProxy,
      ethTxOptions
    );
    const receipt = await tx.wait();
    if (this.verbose) {
      console.log(`ChainTypeManager was set in ValidatorTimelock, gas used: ${receipt.gasUsed.toString()}`);
    }
  }

  public async deployMulticall3(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const contractAddress = await this.deployViaCreate2("Multicall3", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_L1_MULTICALL3_ADDR=${contractAddress}`);
    }
  }

  public async deployDAValidators(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;

    // This address only makes sense on the L1, but we deploy it anyway to keep the script simple
    const rollupValidatorBytecode = await this.loadFromDAFolder("RollupL1DAValidator");
    const rollupDAValidatorAddress = await this.deployViaCreate2(
      "RollupL1DAValidator",
      [],
      create2Salt,
      ethTxOptions,
      undefined,
      rollupValidatorBytecode
    );
    if (this.verbose) {
      console.log(`CONTRACTS_L1_ROLLUP_DA_VALIDATOR=${rollupDAValidatorAddress}`);
    }
    const validiumDAValidatorAddress = await this.deployViaCreate2(
      "ValidiumL1DAValidator",
      [],
      create2Salt,
      ethTxOptions,
      undefined
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_VALIDIUM_DA_VALIDATOR=${validiumDAValidatorAddress}`);
    }
    // This address only makes sense on the Sync Layer, but we deploy it anyway to keep the script simple
    const relayedSLDAValidator = await this.deployViaCreate2("RelayedSLDAValidator", [], create2Salt, ethTxOptions);
    if (this.verbose) {
      console.log(`CONTRACTS_L1_RELAYED_SL_DA_VALIDATOR=${relayedSLDAValidator}`);
    }
    this.addresses.RollupL1DAValidator = rollupDAValidatorAddress;
    this.addresses.ValidiumL1DAValidator = validiumDAValidatorAddress;
    this.addresses.RelayedSLDAValidator = relayedSLDAValidator;
  }

  public async updateBlobVersionedHashRetrieverZkMode() {
    if (!this.isZkMode()) {
      throw new Error("`updateBlobVersionedHashRetrieverZk` should be only called when deploying on zkSync network");
    }

    console.log("BlobVersionedHashRetriever is not needed within zkSync network and won't be deployed");

    // 0 is not allowed, we need to some random non-zero value. Let it be 0x1000000000000000000000000000000000000001
    console.log("CONTRACTS_BLOB_VERSIONED_HASH_RETRIEVER_ADDR=0x1000000000000000000000000000000000000001");
    this.addresses.BlobVersionedHashRetriever = "0x1000000000000000000000000000000000000001";
  }

  public async deployBlobVersionedHashRetriever(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    // solc contracts/zksync/utils/blobVersionedHashRetriever.yul --strict-assembly --bin
    const bytecode = "0x600b600b5f39600b5ff3fe5f358049805f5260205ff3";

    const contractAddress = await this.deployBytecodeViaCreate2(
      "BlobVersionedHashRetriever",
      bytecode,
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_BLOB_VERSIONED_HASH_RETRIEVER_ADDR=${contractAddress}`);
    }

    this.addresses.BlobVersionedHashRetriever = contractAddress;
  }

  public transparentUpgradableProxyContract(address, signerOrProvider: Signer | providers.Provider) {
    return ITransparentUpgradeableProxyFactory.connect(address, signerOrProvider);
  }

  public create2FactoryContract(signerOrProvider: Signer | providers.Provider) {
    return SingletonFactoryFactory.connect(this.addresses.Create2Factory, signerOrProvider);
  }

  public bridgehubContract(signerOrProvider: Signer | providers.Provider) {
    return BridgehubFactory.connect(this.addresses.Bridgehub.BridgehubProxy, signerOrProvider);
  }

  public chainTypeManagerContract(signerOrProvider: Signer | providers.Provider) {
    return ChainTypeManagerFactory.connect(this.addresses.StateTransition.StateTransitionProxy, signerOrProvider);
  }

  public stateTransitionContract(signerOrProvider: Signer | providers.Provider) {
    return IZKChainFactory.connect(this.addresses.StateTransition.DiamondProxy, signerOrProvider);
  }

  public governanceContract(signerOrProvider: Signer | providers.Provider) {
    return IGovernanceFactory.connect(this.addresses.Governance, signerOrProvider);
  }

  public validatorTimelock(signerOrProvider: Signer | providers.Provider) {
    return ValidatorTimelockFactory.connect(this.addresses.ValidatorTimeLock, signerOrProvider);
  }

  public defaultSharedBridge(signerOrProvider: Signer | providers.Provider) {
    return IL1AssetRouterFactory.connect(this.addresses.Bridges.SharedBridgeProxy, signerOrProvider);
  }

  public l1NullifierContract(signerOrProvider: Signer | providers.Provider) {
    return IL1NullifierFactory.connect(this.addresses.Bridges.L1NullifierProxy, signerOrProvider);
  }

  public nativeTokenVault(signerOrProvider: Signer | providers.Provider) {
    return IL1NativeTokenVaultFactory.connect(this.addresses.Bridges.NativeTokenVaultProxy, signerOrProvider);
  }

  public ctmDeploymentTracker(signerOrProvider: Signer | providers.Provider) {
    return ICTMDeploymentTrackerFactory.connect(this.addresses.Bridgehub.CTMDeploymentTrackerProxy, signerOrProvider);
  }

  public baseTokenContract(signerOrProvider: Signer | providers.Provider) {
    return ERC20Factory.connect(this.addresses.BaseToken, signerOrProvider);
  }

  public proxyAdminContract(signerOrProvider: Signer | providers.Provider) {
    return ProxyAdminFactory.connect(this.addresses.TransparentProxyAdmin, signerOrProvider);
  }

  private async getL1ChainId(): Promise<number> {
    const l1ChainId = this.isZkMode() ? getNumberFromEnv("ETH_CLIENT_CHAIN_ID") : await this.deployWallet.getChainId();
    return +l1ChainId;
  }
}
