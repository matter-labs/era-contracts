import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";

import type { BigNumberish, providers, Signer, Wallet } from "ethers";
import { ethers } from "ethers";
import { hexlify, Interface } from "ethers/lib/utils";
import type { DeployedAddresses } from "./deploy-utils";
import { deployedAddressesFromEnv, deployBytecodeViaCreate2, deployViaCreate2 } from "./deploy-utils";
import {
  packSemver,
  readBatchBootloaderBytecode,
  readSystemContractsBytecode,
  unpackStringSemVer,
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
  compileInitialCutHash,
} from "./utils";
import { IBridgehubFactory } from "../typechain/IBridgehubFactory";
import { IGovernanceFactory } from "../typechain/IGovernanceFactory";
import { IStateTransitionManagerFactory } from "../typechain/IStateTransitionManagerFactory";
import { ITransparentUpgradeableProxyFactory } from "../typechain/ITransparentUpgradeableProxyFactory";
import { ProxyAdminFactory } from "../typechain/ProxyAdminFactory";

import { IZkSyncHyperchainFactory } from "../typechain/IZkSyncHyperchainFactory";
import { L1SharedBridgeFactory } from "../typechain/L1SharedBridgeFactory";

import { SingletonFactoryFactory } from "../typechain/SingletonFactoryFactory";
import { ValidatorTimelockFactory } from "../typechain/ValidatorTimelockFactory";
import type { FacetCut } from "./diamondCut";
import { getCurrentFacetCutsForAdd } from "./diamondCut";

import { ChainAdminFactory, ERC20Factory } from "../typechain";
import type { Contract, Overrides } from "@ethersproject/contracts";

let L2_BOOTLOADER_BYTECODE_HASH: string;
let L2_DEFAULT_ACCOUNT_BYTECODE_HASH: string;

export interface DeployerConfig {
  deployWallet: Wallet;
  addresses?: DeployedAddresses;
  ownerAddress?: string;
  verbose?: boolean;
  bootloaderBytecodeHash?: string;
  defaultAccountBytecodeHash?: string;
}

export interface Operation {
  calls: { target: string; value: BigNumberish; data: string }[];
  predecessor: string;
  salt: string;
}

export type OperationOrString = Operation | string;

export class Deployer {
  public addresses: DeployedAddresses;
  public deployWallet: Wallet;
  public verbose: boolean;
  public chainId: number;
  public ownerAddress: string;

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
  }

  public async initialZkSyncHyperchainDiamondCut(extraFacets?: FacetCut[]) {
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

    return compileInitialCutHash(
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
  }

  public async deployCreate2Factory(ethTxOptions?: ethers.providers.TransactionRequest) {
    if (this.verbose) {
      console.log("Deploying Create2 factory");
    }

    const contractFactory = await hardhat.ethers.getContractFactory("SingletonFactory", {
      signer: this.deployWallet,
    });

    const create2Factory = await contractFactory.deploy(...[ethTxOptions]);
    const rec = await create2Factory.deployTransaction.wait();

    if (this.verbose) {
      console.log(`CONTRACTS_CREATE2_FACTORY_ADDR=${create2Factory.address}`);
      console.log(`Create2 factory deployed, gasUsed: ${rec.gasUsed.toString()}`);
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
    libraries?: any
  ) {
    const result = await deployViaCreate2(
      this.deployWallet,
      contractName,
      args,
      create2Salt,
      ethTxOptions,
      this.addresses.Create2Factory,
      this.verbose,
      libraries
    );
    return result[0];
  }

  private async deployBytecodeViaCreate2(
    contractName: string,
    bytecode: ethers.BytesLike,
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ): Promise<string> {
    const result = await deployBytecodeViaCreate2(
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
    ethTxOptions.gasLimit ??= 10_000_000;
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
    const contractAddress = await this.deployViaCreate2(
      "ChainAdmin",
      [this.ownerAddress, ethers.constants.AddressZero],
      create2Salt,
      ethTxOptions
    );
    if (this.verbose) {
      console.log(`CONTRACTS_CHAIN_ADMIN_ADDR=${contractAddress}`);
    }
    this.addresses.ChainAdmin = contractAddress;
  }

  public async deployBridgehubImplementation(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("Bridgehub", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_BRIDGEHUB_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridgehub.BridgehubImplementation = contractAddress;
  }

  public async deployTransparentProxyAdmin(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    if (this.verbose) {
      console.log("Deploying Proxy Admin");
    }
    // Note: we cannot deploy using Create2, as the owner of the ProxyAdmin is msg.sender
    const contractFactory = await hardhat.ethers.getContractFactory("ProxyAdmin", {
      signer: this.deployWallet,
    });

    const proxyAdmin = await contractFactory.deploy(...[ethTxOptions]);
    const rec = await proxyAdmin.deployTransaction.wait();

    if (this.verbose) {
      console.log(
        `Proxy admin deployed, gasUsed: ${rec.gasUsed.toString()}, tx hash ${rec.transactionHash}, expected address: ${
          proxyAdmin.address
        }`
      );
      console.log(`CONTRACTS_TRANSPARENT_PROXY_ADMIN_ADDR=${proxyAdmin.address}`);
    }

    this.addresses.TransparentProxyAdmin = proxyAdmin.address;

    const tx = await proxyAdmin.transferOwnership(this.addresses.Governance);
    const receipt = await tx.wait();

    if (this.verbose) {
      console.log(
        `ProxyAdmin ownership transferred to Governance in tx ${
          receipt.transactionHash
        }, gas used: ${receipt.gasUsed.toString()}`
      );
    }
  }

  public async deployBridgehubProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;

    const bridgehub = new Interface(hardhat.artifacts.readArtifactSync("Bridgehub").abi);

    const initCalldata = bridgehub.encodeFunctionData("initialize", [this.ownerAddress]);

    const contractAddress = await this.deployViaCreate2(
      "TransparentUpgradeableProxy",
      [this.addresses.Bridgehub.BridgehubImplementation, this.addresses.TransparentProxyAdmin, initCalldata],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_BRIDGEHUB_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridgehub.BridgehubProxy = contractAddress;
  }

  public async deployStateTransitionManagerImplementation(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2(
      "StateTransitionManager",
      [this.addresses.Bridgehub.BridgehubProxy, getNumberFromEnv("CONTRACTS_MAX_NUMBER_OF_HYPERCHAINS")],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_STATE_TRANSITION_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.StateTransitionImplementation = contractAddress;
  }

  public async deployStateTransitionManagerProxy(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest,
    extraFacets?: FacetCut[]
  ) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const genesisBatchHash = getHashFromEnv("CONTRACTS_GENESIS_ROOT"); // TODO: confusing name
    const genesisRollupLeafIndex = getNumberFromEnv("CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX");
    const genesisBatchCommitment = getHashFromEnv("CONTRACTS_GENESIS_BATCH_COMMITMENT");
    const diamondCut = await this.initialZkSyncHyperchainDiamondCut(extraFacets);
    const protocolVersion = packSemver(...unpackStringSemVer(process.env.CONTRACTS_GENESIS_PROTOCOL_SEMANTIC_VERSION));

    const stateTransitionManager = new Interface(hardhat.artifacts.readArtifactSync("StateTransitionManager").abi);

    const chainCreationParams = {
      genesisUpgrade: this.addresses.StateTransition.GenesisUpgrade,
      genesisBatchHash,
      genesisIndexRepeatedStorageChanges: genesisRollupLeafIndex,
      genesisBatchCommitment,
      diamondCut,
    };

    const initCalldata = stateTransitionManager.encodeFunctionData("initialize", [
      {
        owner: this.addresses.Governance,
        validatorTimelock: this.addresses.ValidatorTimeLock,
        chainCreationParams,
        protocolVersion,
      },
    ]);

    const contractAddress = await this.deployViaCreate2(
      "TransparentUpgradeableProxy",
      [
        this.addresses.StateTransition.StateTransitionImplementation,
        this.addresses.TransparentProxyAdmin,
        initCalldata,
      ],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`StateTransitionManagerProxy deployed, with protocol version: ${protocolVersion}`);
      console.log(`CONTRACTS_STATE_TRANSITION_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.StateTransitionProxy = contractAddress;
  }

  public async deployAdminFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("AdminFacet", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_ADMIN_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.AdminFacet = contractAddress;
  }

  public async deployMailboxFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const eraChainId = getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID");
    const contractAddress = await this.deployViaCreate2("MailboxFacet", [eraChainId], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`Mailbox deployed with era chain id: ${eraChainId}`);
      console.log(`CONTRACTS_MAILBOX_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.MailboxFacet = contractAddress;
  }

  public async deployExecutorFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("ExecutorFacet", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_EXECUTOR_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.ExecutorFacet = contractAddress;
  }

  public async deployGettersFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("GettersFacet", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_GETTERS_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.GettersFacet = contractAddress;
  }

  public async deployVerifier(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;

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
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2(
      dummy ? "DummyL1ERC20Bridge" : "L1ERC20Bridge",
      [this.addresses.Bridges.SharedBridgeProxy],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_ERC20_BRIDGE_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.ERC20BridgeImplementation = contractAddress;
  }

  public async setParametersSharedBridge() {
    const sharedBridge = L1SharedBridgeFactory.connect(this.addresses.Bridges.SharedBridgeProxy, this.deployWallet);
    const data1 = sharedBridge.interface.encodeFunctionData("setL1Erc20Bridge", [
      this.addresses.Bridges.ERC20BridgeProxy,
    ]);
    const data2 = sharedBridge.interface.encodeFunctionData("setEraPostDiamondUpgradeFirstBatch", [
      process.env.CONTRACTS_ERA_POST_DIAMOND_UPGRADE_FIRST_BATCH ?? 1,
    ]);
    const data3 = sharedBridge.interface.encodeFunctionData("setEraPostLegacyBridgeUpgradeFirstBatch", [
      process.env.CONTRACTS_ERA_POST_LEGACY_BRIDGE_UPGRADE_FIRST_BATCH ?? 1,
    ]);
    const data4 = sharedBridge.interface.encodeFunctionData("setEraLegacyBridgeLastDepositTime", [
      process.env.CONTRACTS_ERA_LEGACY_UPGRADE_LAST_DEPOSIT_BATCH ?? 1,
      process.env.CONTRACTS_ERA_LEGACY_UPGRADE_LAST_DEPOSIT_TX_NUMBER ?? 0,
    ]);
    await this.executeUpgrade(this.addresses.Bridges.SharedBridgeProxy, 0, data1);
    await this.executeUpgrade(this.addresses.Bridges.SharedBridgeProxy, 0, data2);
    await this.executeUpgrade(this.addresses.Bridges.SharedBridgeProxy, 0, data3);
    await this.executeUpgrade(this.addresses.Bridges.SharedBridgeProxy, 0, data4);
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
    overrides?: Overrides,
    printOperation: boolean = false
  ): Promise<ethers.ContractReceipt> {
    if (useGovernance) {
      const cdata = contract.interface.encodeFunctionData(fname, fargs);
      return this.executeUpgrade(contract.address, value, cdata, printOperation);
    } else {
      const tx: ethers.ContractTransaction = await contract[fname](...fargs, ...(overrides ? [overrides] : []));
      return await tx.wait();
    }
  }

  /// this should be only use for local testing
  public async executeUpgrade(
    targetAddress: string,
    value: BigNumberish,
    callData: string,
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
    const executeTX = await governance.execute(operation, { value: value });
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

  // used for testing, mimics original deployment process.
  // we don't use the real implementation, as we need the address to be independent
  public async deployERC20BridgeProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const initCalldata = new Interface(hardhat.artifacts.readArtifactSync("L1ERC20Bridge").abi).encodeFunctionData(
      "initialize"
    );
    const contractAddress = await this.deployViaCreate2(
      "TransparentUpgradeableProxy",
      [this.addresses.Bridges.ERC20BridgeImplementation, this.addresses.TransparentProxyAdmin, initCalldata],
      create2Salt,
      ethTxOptions
    );
    if (this.verbose) {
      console.log(`CONTRACTS_L1_ERC20_BRIDGE_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.ERC20BridgeProxy = contractAddress;
  }

  public async deploySharedBridgeImplementation(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const tokens = getTokens();
    const l1WethToken = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;
    const eraChainId = getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID");
    const eraDiamondProxy = getAddressFromEnv("CONTRACTS_ERA_DIAMOND_PROXY_ADDR");
    const contractAddress = await this.deployViaCreate2(
      "L1SharedBridge",
      [l1WethToken, this.addresses.Bridgehub.BridgehubProxy, eraChainId, eraDiamondProxy],
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
    ethTxOptions.gasLimit ??= 10_000_000;
    const initCalldata = new Interface(hardhat.artifacts.readArtifactSync("L1SharedBridge").abi).encodeFunctionData(
      "initialize",
      [this.addresses.Governance]
    );
    const contractAddress = await this.deployViaCreate2(
      "TransparentUpgradeableProxy",
      [this.addresses.Bridges.SharedBridgeImplementation, this.addresses.TransparentProxyAdmin, initCalldata],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_SHARED_BRIDGE_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.SharedBridgeProxy = contractAddress;
  }

  public async sharedBridgeSetEraPostUpgradeFirstBatch(ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const sharedBridge = L1SharedBridgeFactory.connect(this.addresses.Bridges.SharedBridgeProxy, this.deployWallet);
    const storageSwitch = getNumberFromEnv("CONTRACTS_SHARED_BRIDGE_UPGRADE_STORAGE_SWITCH");
    const tx = await sharedBridge.setEraPostUpgradeFirstBatch(storageSwitch);
    const receipt = await tx.wait();
    if (this.verbose) {
      console.log(`Era first post upgrade batch set, gas used: ${receipt.gasUsed.toString()}`);
    }
  }

  public async registerSharedBridge(ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const bridgehub = this.bridgehubContract(this.deployWallet);

    /// registering ETH as a valid token, with address 1.
    const tx2 = await bridgehub.addToken(ADDRESS_ONE);
    const receipt2 = await tx2.wait();

    const tx3 = await bridgehub.setSharedBridge(this.addresses.Bridges.SharedBridgeProxy);
    const receipt3 = await tx3.wait();
    if (this.verbose) {
      console.log(
        `Shared bridge was registered, gas used: ${receipt3.gasUsed.toString()} and ${receipt2.gasUsed.toString()}`
      );
    }
  }

  public async deployStateTransitionDiamondInit(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("DiamondInit", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_DIAMOND_INIT_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.DiamondInit = contractAddress;
  }

  public async deployDefaultUpgrade(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("DefaultUpgrade", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_DEFAULT_UPGRADE_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.DefaultUpgrade = contractAddress;
  }

  public async deployHyperchainsUpgrade(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("UpgradeHyperchains", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_HYPERCHAIN_UPGRADE_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.DefaultUpgrade = contractAddress;
  }

  public async deployGenesisUpgrade(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("GenesisUpgrade", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_GENESIS_UPGRADE_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.GenesisUpgrade = contractAddress;
  }

  public async deployBridgehubContract(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployBridgehubImplementation(create2Salt, { gasPrice, nonce });
    await this.deployBridgehubProxy(create2Salt, { gasPrice });
  }

  public async deployStateTransitionManagerContract(
    create2Salt: string,
    extraFacets?: FacetCut[],
    gasPrice?: BigNumberish,
    nonce?
  ) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployStateTransitionDiamondFacets(create2Salt, gasPrice, nonce);
    await this.deployStateTransitionManagerImplementation(create2Salt, { gasPrice });
    await this.deployStateTransitionManagerProxy(create2Salt, { gasPrice }, extraFacets);
    await this.registerStateTransitionManager();
  }

  public async deployStateTransitionDiamondFacets(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployExecutorFacet(create2Salt, { gasPrice, nonce: nonce });
    await this.deployAdminFacet(create2Salt, { gasPrice, nonce: nonce + 1 });
    await this.deployMailboxFacet(create2Salt, { gasPrice, nonce: nonce + 2 });
    await this.deployGettersFacet(create2Salt, { gasPrice, nonce: nonce + 3 });
    await this.deployStateTransitionDiamondInit(create2Salt, { gasPrice, nonce: nonce + 4 });
  }

  public async registerStateTransitionManager() {
    const bridgehub = this.bridgehubContract(this.deployWallet);

    if (!(await bridgehub.stateTransitionManagerIsRegistered(this.addresses.StateTransition.StateTransitionProxy))) {
      const tx = await bridgehub.addStateTransitionManager(this.addresses.StateTransition.StateTransitionProxy);

      const receipt = await tx.wait();
      if (this.verbose) {
        console.log(`StateTransition System registered, gas used: ${receipt.gasUsed.toString()}`);
      }
    }
  }

  public async registerHyperchain(
    baseTokenAddress: string,
    validiumMode: boolean,
    extraFacets?: FacetCut[],
    gasPrice?: BigNumberish,
    nonce?,
    predefinedChainId?: string,
    useGovernance: boolean = false
  ) {
    const gasLimit = 10_000_000;

    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    const bridgehub = this.bridgehubContract(this.deployWallet);
    const stateTransitionManager = this.stateTransitionManagerContract(this.deployWallet);

    const inputChainId = predefinedChainId || getNumberFromEnv("CHAIN_ETH_ZKSYNC_NETWORK_ID");
    const admin = process.env.CHAIN_ADMIN_ADDRESS || this.ownerAddress;
    const diamondCutData = await this.initialZkSyncHyperchainDiamondCut(extraFacets);
    const initialDiamondCut = new ethers.utils.AbiCoder().encode([DIAMOND_CUT_DATA_ABI_STRING], [diamondCutData]);

    const receipt = await this.executeDirectOrGovernance(
      useGovernance,
      bridgehub,
      "createNewChain",
      [
        inputChainId,
        this.addresses.StateTransition.StateTransitionProxy,
        baseTokenAddress,
        Date.now(),
        admin,
        initialDiamondCut,
      ],
      0,
      {
        gasPrice,
        nonce,
        gasLimit,
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

    if (this.verbose) {
      console.log(`Hyperchain registered, gas used: ${receipt.gasUsed.toString()} and ${receipt.gasUsed.toString()}`);
      console.log(`Hyperchain registration tx hash: ${receipt.transactionHash}`);

      console.log(`CHAIN_ETH_ZKSYNC_NETWORK_ID=${parseInt(chainId, 16)}`);

      console.log(`CONTRACTS_BASE_TOKEN_ADDR=${baseTokenAddress}`);
    }
    if (!predefinedChainId) {
      const diamondProxyAddress =
        "0x" +
        receipt.logs
          .find((log) => log.topics[0] == stateTransitionManager.interface.getEventTopic("NewHyperchain"))
          .topics[2].slice(26);
      this.addresses.StateTransition.DiamondProxy = diamondProxyAddress;
      if (this.verbose) {
        console.log(`CONTRACTS_DIAMOND_PROXY_ADDR=${diamondProxyAddress}`);
      }
    }
    this.chainId = parseInt(chainId, 16);

    const validatorOneAddress = getAddressFromEnv("ETH_SENDER_SENDER_OPERATOR_COMMIT_ETH_ADDR");
    const validatorTwoAddress = getAddressFromEnv("ETH_SENDER_SENDER_OPERATOR_BLOBS_ETH_ADDR");
    const validatorTimelock = this.validatorTimelock(this.deployWallet);
    const txRegisterValidator = await validatorTimelock.addValidator(chainId, validatorOneAddress, {
      gasPrice,
      nonce,
      gasLimit,
    });
    const receiptRegisterValidator = await txRegisterValidator.wait();
    if (this.verbose) {
      console.log(
        `Validator registered, gas used: ${receiptRegisterValidator.gasUsed.toString()}, tx hash: ${
          txRegisterValidator.hash
        }`
      );
    }

    nonce++;

    const tx3 = await validatorTimelock.addValidator(chainId, validatorTwoAddress, {
      gasPrice,
      nonce,
      gasLimit,
    });
    const receipt3 = await tx3.wait();
    if (this.verbose) {
      console.log(`Validator 2 registered, gas used: ${receipt3.gasUsed.toString()}`);
    }

    const diamondProxy = this.stateTransitionContract(this.deployWallet);
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
    const stm = this.stateTransitionManagerContract(this.deployWallet);
    const diamondProxyAddress = await stm.getHyperchain(this.chainId);
    const hyperchain = IZkSyncHyperchainFactory.connect(diamondProxyAddress, this.deployWallet);

    const receipt = await (await hyperchain.setPendingAdmin(this.addresses.ChainAdmin)).wait();
    if (this.verbose) {
      console.log(`ChainAdmin set as pending admin, gas used: ${receipt.gasUsed.toString()}`);
    }

    const acceptAdminData = hyperchain.interface.encodeFunctionData("acceptAdmin");
    const chainAdmin = ChainAdminFactory.connect(this.addresses.ChainAdmin, this.deployWallet);
    const multicallTx = await chainAdmin.multicall(
      [
        {
          target: hyperchain.address,
          value: 0,
          data: acceptAdminData,
        },
      ],
      true
    );
    await multicallTx.wait();

    if (this.verbose) {
      console.log("Pending admin successfully accepted");
    }
  }

  public async registerToken(tokenAddress: string, useGovernance: boolean = false) {
    const bridgehub = this.bridgehubContract(this.deployWallet);

    const receipt = await this.executeDirectOrGovernance(useGovernance, bridgehub, "addToken", [tokenAddress], 0);

    if (this.verbose) {
      console.log(`Token ${tokenAddress} was registered, gas used: ${receipt.gasUsed.toString()}`);
    }
  }

  public async deploySharedBridgeContracts(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deploySharedBridgeImplementation(create2Salt, { gasPrice, nonce: nonce });
    await this.deploySharedBridgeProxy(create2Salt, { gasPrice, nonce: nonce + 1 });
    await this.registerSharedBridge({ gasPrice, nonce: nonce + 2 });
  }

  public async deployValidatorTimelock(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const executionDelay = getNumberFromEnv("CONTRACTS_VALIDATOR_TIMELOCK_EXECUTION_DELAY");
    const eraChainId = getNumberFromEnv("CONTRACTS_ERA_CHAIN_ID");
    const contractAddress = await this.deployViaCreate2(
      "ValidatorTimelock",
      [this.ownerAddress, executionDelay, eraChainId],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_VALIDATOR_TIMELOCK_ADDR=${contractAddress}`);
    }
    this.addresses.ValidatorTimeLock = contractAddress;
  }

  public async setStateTransitionManagerInValidatorTimelock(ethTxOptions: ethers.providers.TransactionRequest) {
    const validatorTimelock = this.validatorTimelock(this.deployWallet);
    const tx = await validatorTimelock.setStateTransitionManager(
      this.addresses.StateTransition.StateTransitionProxy,
      ethTxOptions
    );
    const receipt = await tx.wait();
    if (this.verbose) {
      console.log(`StateTransitionManager was set in ValidatorTimelock, gas used: ${receipt.gasUsed.toString()}`);
    }
  }

  public async deployMulticall3(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("Multicall3", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_L1_MULTICALL3_ADDR=${contractAddress}`);
    }
  }

  public async deployBlobVersionedHashRetriever(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    ethTxOptions.gasLimit ??= 10_000_000;
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
    return IBridgehubFactory.connect(this.addresses.Bridgehub.BridgehubProxy, signerOrProvider);
  }

  public stateTransitionManagerContract(signerOrProvider: Signer | providers.Provider) {
    return IStateTransitionManagerFactory.connect(
      this.addresses.StateTransition.StateTransitionProxy,
      signerOrProvider
    );
  }

  public stateTransitionContract(signerOrProvider: Signer | providers.Provider) {
    return IZkSyncHyperchainFactory.connect(this.addresses.StateTransition.DiamondProxy, signerOrProvider);
  }

  public governanceContract(signerOrProvider: Signer | providers.Provider) {
    return IGovernanceFactory.connect(this.addresses.Governance, signerOrProvider);
  }

  public validatorTimelock(signerOrProvider: Signer | providers.Provider) {
    return ValidatorTimelockFactory.connect(this.addresses.ValidatorTimeLock, signerOrProvider);
  }

  public defaultSharedBridge(signerOrProvider: Signer | providers.Provider) {
    return L1SharedBridgeFactory.connect(this.addresses.Bridges.SharedBridgeProxy, signerOrProvider);
  }

  public baseTokenContract(signerOrProvider: Signer | providers.Provider) {
    return ERC20Factory.connect(this.addresses.BaseToken, signerOrProvider);
  }

  public proxyAdminContract(signerOrProvider: Signer | providers.Provider) {
    return ProxyAdminFactory.connect(this.addresses.TransparentProxyAdmin, signerOrProvider);
  }
}
