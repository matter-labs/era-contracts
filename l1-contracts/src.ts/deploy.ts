import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";

import type { BigNumberish, providers, Signer, Wallet } from "ethers";
import { ethers } from "ethers";
import { hexlify, Interface } from "ethers/lib/utils";
import type { DeployedAddresses } from "../scripts/utils";
import {
  ADDRESS_ONE,
  deployedAddressesFromEnv,
  getAddressFromEnv,
  getHashFromEnv,
  getNumberFromEnv,
  getTokens,
  readBatchBootloaderBytecode,
  readSystemContractsBytecode,
  SYSTEM_CONFIG,
} from "../scripts/utils";
import { PubdataPricingMode } from "../test/unit_tests/utils";
import { IBridgehubFactory } from "../typechain/IBridgehubFactory";
import { IGovernanceFactory } from "../typechain/IGovernanceFactory";
import { IStateTransitionManagerFactory } from "../typechain/IStateTransitionManagerFactory";
import { ITransparentUpgradeableProxyFactory } from "../typechain/ITransparentUpgradeableProxyFactory";
import { ProxyAdminFactory } from "../typechain/ProxyAdminFactory";

import { IZkSyncStateTransitionFactory } from "../typechain/IZkSyncStateTransitionFactory";
import { L1ERC20BridgeFactory } from "../typechain/L1ERC20BridgeFactory";
import { ERC20BridgeMessageParsingFactory } from "../typechain/ERC20BridgeMessageParsingFactory";

import { L1WethBridgeFactory } from "../typechain/L1WethBridgeFactory";
import { SingletonFactoryFactory } from "../typechain/SingletonFactoryFactory";
import { ValidatorTimelockFactory } from "../typechain/ValidatorTimelockFactory";
import { deployViaCreate2 } from "./deploy-utils";
import type { FacetCut } from "./diamondCut";
import { diamondCut, getCurrentFacetCutsForAdd } from "./diamondCut";

import { hashL2Bytecode } from "./utils";

import { ERC20Factory } from "../typechain";

let L2_BOOTLOADER_BYTECODE_HASH: string;
let L2_DEFAULT_ACCOUNT_BYTECODE_HASH: string;
export const EraLegacyChainId = 324;
export const EraLegacyDiamondProxyAddress = "0x32400084C286CF3E17e7B677ea9583e60a000324";

export interface DeployerConfig {
  deployWallet: Wallet;
  addresses?: DeployedAddresses;
  ownerAddress?: string;
  verbose?: boolean;
  bootloaderBytecodeHash?: string;
  defaultAccountBytecodeHash?: string;
}

export class Deployer {
  public addresses: DeployedAddresses;
  private deployWallet: Wallet;
  public verbose: boolean;
  public chainId: number;
  private ownerAddress: string;

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
  }

  public async initialZkSyncStateTransitionDiamondCut(extraFacets?: FacetCut[]) {
    let facetCuts: FacetCut[] = Object.values(
      await getCurrentFacetCutsForAdd(
        this.addresses.StateTransition.AdminFacet,
        this.addresses.StateTransition.GettersFacet,
        this.addresses.StateTransition.MailboxFacet,
        this.addresses.StateTransition.ExecutorFacet
      )
    );
    facetCuts = facetCuts.concat(extraFacets ?? []);

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

    const diamondInitCalldata = DiamondInit.encodeFunctionData("initialize", [
      // these first 7 values are set in the contract
      {
        chainId: "0x0000000000000000000000000000000000000000000000000000000000000001",
        bridgehub: "0x0000000000000000000000000000000000001234",
        stateTransitionManager: "0x0000000000000000000000000000000000002234",
        protocolVersion: "0x0000000000000000000000000000000000002234",
        governor: "0x0000000000000000000000000000000000003234",
        admin: "0x0000000000000000000000000000000000004234",
        baseToken: "0x0000000000000000000000000000000000004234",
        baseTokenBridge: "0x0000000000000000000000000000000000004234",
        storedBatchZero: "0x0000000000000000000000000000000000000000000000000000000000005432",
        verifier: this.addresses.StateTransition.Verifier,
        verifierParams,
        l2BootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
        l2DefaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
        priorityTxMaxGasLimit,
        feeParams,
      },
    ]);

    return diamondCut(
      facetCuts,
      this.addresses.StateTransition.DiamondInit,
      "0x" + diamondInitCalldata.slice(2 + 292 * 2)
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

  private async deployViaCreate2(
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
      console.log("Deploying Proxy Admin factory");
    }

    const contractFactory = await hardhat.ethers.getContractFactory("ProxyAdmin", {
      signer: this.deployWallet,
    });

    const proxyAdmin = await contractFactory.deploy(...[ethTxOptions]);
    const rec = await proxyAdmin.deployTransaction.wait();

    if (this.verbose) {
      console.log(`CONTRACTS_TRANSPARENT_PROXY_ADMIN_ADDR=${proxyAdmin.address}`);
      console.log(`Proxy admin deployed, gasUsed: ${rec.gasUsed.toString()}`);
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

  public async deployStateTransitionImplementation(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2(
      "StateTransitionManager",
      [this.addresses.Bridgehub.BridgehubProxy],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_STATE_TRANSITION_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.StateTransitionImplementation = contractAddress;
  }

  public async deployStateTransitionProxy(
    create2Salt: string,
    ethTxOptions: ethers.providers.TransactionRequest,
    extraFacets?: FacetCut[]
  ) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const genesisBatchHash = getHashFromEnv("CONTRACTS_GENESIS_ROOT"); // TODO: confusing name
    const genesisRollupLeafIndex = getNumberFromEnv("CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX");
    const genesisBatchCommitment = getHashFromEnv("CONTRACTS_GENESIS_BATCH_COMMITMENT");
    const diamondCut = await this.initialZkSyncStateTransitionDiamondCut(extraFacets);
    const protocolVersion = getNumberFromEnv("CONTRACTS_LATEST_PROTOCOL_VERSION");

    const stateTransition = new Interface(hardhat.artifacts.readArtifactSync("StateTransitionManager").abi);

    const initCalldata = stateTransition.encodeFunctionData("initialize", [
      {
        governor: this.ownerAddress,
        genesisUpgrade: this.addresses.StateTransition.GenesisUpgrade,
        genesisBatchHash,
        genesisIndexRepeatedStorageChanges: genesisRollupLeafIndex,
        genesisBatchCommitment,
        diamondCut,
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
    const contractAddress = await this.deployViaCreate2("MailboxFacet", [], create2Salt, ethTxOptions);

    if (this.verbose) {
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
    const contractAddress = await this.deployViaCreate2("Verifier", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_VERIFIER_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.Verifier = contractAddress;
  }

  public async deployERC20BridgeMessageParsing(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("ERC20BridgeMessageParsing", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_L1_ERC20_BRIDGE_MESSAGE_PARSING_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.ERC20BridgeMessageParsing = contractAddress;
  }

  public async deployERC20BridgeImplementation(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2(
      "L1ERC20Bridge",
      [this.addresses.Bridgehub.BridgehubProxy],
      create2Salt,
      ethTxOptions,
      { ERC20BridgeMessageParsing: this.addresses.Bridges.ERC20BridgeMessageParsing }
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_ERC20_BRIDGE_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.ERC20BridgeImplementation = contractAddress;
  }

  public async deployERC20BridgeProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2(
      "TransparentUpgradeableProxy",
      [this.addresses.Bridges.ERC20BridgeImplementation, this.addresses.TransparentProxyAdmin, "0x"],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_ERC20_BRIDGE_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.ERC20BridgeProxy = contractAddress;
  }

  public async registerERC20Bridge(ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const bridgehub = this.bridgehubContract(this.deployWallet);

    const tx = await bridgehub.addTokenBridge(this.addresses.Bridges.ERC20BridgeProxy);

    const receipt = await tx.wait();
    if (this.verbose) {
      console.log(`ERC20 bridge was registered, gas used: ${receipt.gasUsed.toString()}`);
    }
  }

  public async deployWethToken(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("WETH9", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_L1_WETH_TOKEN_ADDR=${contractAddress}`);
    }
  }

  public async deployWethBridgeImplementation(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    const tokens = getTokens(process.env.CHAIN_ETH_NETWORK || "localhost");
    const l1WethToken = tokens.find((token: { symbol: string }) => token.symbol == "WETH")!.address;
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2(
      "L1WethBridge",
      [l1WethToken, this.addresses.Bridgehub.BridgehubProxy],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_WETH_BRIDGE_IMPL_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.WethBridgeImplementation = contractAddress;
  }

  public async deployWethBridgeProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2(
      "TransparentUpgradeableProxy",
      [this.addresses.Bridges.WethBridgeImplementation, this.addresses.TransparentProxyAdmin, "0x"],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_WETH_BRIDGE_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.WethBridgeProxy = contractAddress;
  }

  public async registerWETHBridge(ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const bridgehub = this.bridgehubContract(this.deployWallet);

    const tx = await bridgehub.addTokenBridge(this.addresses.Bridges.WethBridgeProxy);
    const receipt = await tx.wait();

    /// registering ETH as a valid token, with address 1.
    const tx2 = await bridgehub.addToken(ADDRESS_ONE);
    const receipt2 = await tx2.wait();

    const tx3 = await bridgehub.setWethBridge(this.addresses.Bridges.WethBridgeProxy);
    await tx3.wait();
    if (this.verbose) {
      console.log(
        `WETH bridge was registered, gas used: ${receipt.gasUsed.toString()} and ${receipt2.gasUsed.toString()}`
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

  public async deployDiamondUpgradeInit(
    create2Salt: string,
    contractVersion: number,
    ethTxOptions: ethers.providers.TransactionRequest
  ) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2(
      `DiamondUpgradeInit${contractVersion}`,
      [],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_DIAMOND_UPGRADE_INIT_ADDR=${contractAddress}`);
    }

    this.addresses.StateTransition.DiamondUpgradeInit = contractAddress;
  }

  public async deployDefaultUpgrade(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("DefaultUpgrade", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_DEFAULT_UPGRADE_ADDR=${contractAddress}`);
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

  public async deployStateTransitionContract(
    create2Salt: string,
    extraFacets?: FacetCut[],
    gasPrice?: BigNumberish,
    nonce?
  ) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployStateTransitionDiamondFacets(create2Salt, gasPrice, nonce);
    await this.deployStateTransitionImplementation(create2Salt, { gasPrice });
    await this.deployStateTransitionProxy(create2Salt, { gasPrice }, extraFacets);
    await this.registerStateTransition();
  }

  public async deployStateTransitionDiamondFacets(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployExecutorFacet(create2Salt, { gasPrice, nonce: nonce });
    await this.deployAdminFacet(create2Salt, { gasPrice, nonce: nonce + 1 });
    await this.deployMailboxFacet(create2Salt, { gasPrice, nonce: nonce + 2 });
    await this.deployGettersFacet(create2Salt, { gasPrice, nonce: nonce + 3 });
    await this.deployVerifier(create2Salt, { gasPrice, nonce: nonce + 4 });
    await this.deployStateTransitionDiamondInit(create2Salt, { gasPrice, nonce: nonce + 5 });
  }

  public async registerStateTransition() {
    const bridgehub = this.bridgehubContract(this.deployWallet);

    const tx = await bridgehub.addStateTransitionManager(this.addresses.StateTransition.StateTransitionProxy);

    const receipt = await tx.wait();
    if (this.verbose) {
      console.log(`StateTransition System registered, gas used: ${receipt.gasUsed.toString()}`);
    }
  }

  public async registerHyperchain(
    baseTokenAddress: string,
    create2Salt: string,
    extraFacets?: FacetCut[],
    gasPrice?: BigNumberish,
    nonce?
  ) {
    const gasLimit = 10_000_000;

    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    const bridgehub = this.bridgehubContract(this.deployWallet);
    const stateTransitionManager = this.stateTransitionManagerContract(this.deployWallet);

    const inputChainId = getNumberFromEnv("CHAIN_ETH_ZKSYNC_NETWORK_ID");
    const governor = this.ownerAddress;
    const diamondCutData = await this.initialZkSyncStateTransitionDiamondCut(extraFacets);
    const initialDiamondCut = new ethers.utils.AbiCoder().encode(
      [
        "tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata)",
      ],
      [diamondCutData]
    );

    const tx = await bridgehub.createNewChain(
      inputChainId,
      this.addresses.StateTransition.StateTransitionProxy,
      baseTokenAddress,
      baseTokenAddress == ADDRESS_ONE
        ? this.addresses.Bridges.WethBridgeProxy
        : this.addresses.Bridges.ERC20BridgeProxy,
      Date.now(),
      governor,
      initialDiamondCut,
      {
        gasPrice,
        nonce,
        gasLimit,
      }
    );
    const receipt = await tx.wait();
    const chainId = receipt.logs.find((log) => log.topics[0] == bridgehub.interface.getEventTopic("NewChain"))
      .topics[1];

    nonce++;

    const diamondProxyAddress =
      "0x" +
      receipt.logs
        .find((log) => log.topics[0] == stateTransitionManager.interface.getEventTopic("StateTransitionNewChain"))
        .topics[2].slice(26);

    this.addresses.StateTransition.DiamondProxy = diamondProxyAddress;
    this.addresses.BaseToken = baseTokenAddress;
    this.addresses.Bridges.BaseTokenBridge =
      baseTokenAddress == ADDRESS_ONE
        ? this.addresses.Bridges.WethBridgeProxy
        : this.addresses.Bridges.ERC20BridgeProxy;
    if (this.verbose) {
      console.log(`Hyperchain registered, gas used: ${receipt.gasUsed.toString()} and ${receipt.gasUsed.toString()}`);
      console.log(`Hyperchain registration tx hash: ${receipt.transactionHash}`);

      console.log(`CHAIN_ETH_ZKSYNC_NETWORK_ID=${parseInt(chainId, 16)}`);
      console.log(`CONTRACTS_DIAMOND_PROXY_ADDR=${diamondProxyAddress}`);
      console.log(`CONTRACTS_BASE_TOKEN_ADDR=${baseTokenAddress}`);
      console.log(
        `CONTRACTS_BASE_TOKEN_BRIDGE_ADDR=${
          baseTokenAddress == ADDRESS_ONE
            ? this.addresses.Bridges.WethBridgeProxy
            : this.addresses.Bridges.ERC20BridgeProxy
        }`
      );
    }
    this.chainId = parseInt(chainId, 16);
  }

  public async registerToken(tokenAddress: string) {
    const bridgehub = this.bridgehubContract(this.deployWallet);

    const tx = await bridgehub.addToken(tokenAddress);

    const receipt = await tx.wait();
    if (this.verbose) {
      console.log(`Token ${tokenAddress} was registered, gas used: ${receipt.gasUsed.toString()}`);
    }
  }

  public async deployBridgeContracts(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployERC20BridgeMessageParsing(create2Salt, { gasPrice, nonce: nonce });
    await this.deployERC20BridgeImplementation(create2Salt, { gasPrice, nonce: nonce + 1 });
    await this.deployERC20BridgeProxy(create2Salt, { gasPrice, nonce: nonce + 2 });
    await this.registerERC20Bridge({ gasPrice, nonce: nonce + 3 });
  }

  public async deployWethBridgeContracts(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployWethBridgeImplementation(create2Salt, { gasPrice, nonce: nonce++ });
    await this.deployWethBridgeProxy(create2Salt, { gasPrice, nonce: nonce++ });
    await this.registerWETHBridge({ gasPrice, nonce: nonce++ });
  }

  public async deployValidatorTimelock(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const executionDelay = getNumberFromEnv("CONTRACTS_VALIDATOR_TIMELOCK_EXECUTION_DELAY");
    const validatorAddress = getAddressFromEnv("ETH_SENDER_SENDER_OPERATOR_COMMIT_ETH_ADDR");
    const contractAddress = await this.deployViaCreate2(
      "ValidatorTimelock",
      [this.ownerAddress, this.addresses.StateTransition.DiamondProxy, executionDelay, validatorAddress],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_VALIDATOR_TIMELOCK_ADDR=${contractAddress}`);
    }

    this.addresses.ValidatorTimeLock = contractAddress;
  }

  public async deployMulticall3(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("Multicall3", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_L1_MULTICALL3_ADDR=${contractAddress}`);
    }
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
    return IZkSyncStateTransitionFactory.connect(this.addresses.StateTransition.DiamondProxy, signerOrProvider);
  }

  public governanceContract(signerOrProvider: Signer | providers.Provider) {
    return IGovernanceFactory.connect(this.addresses.Governance, signerOrProvider);
  }

  public validatorTimelock(signerOrProvider: Signer | providers.Provider) {
    return ValidatorTimelockFactory.connect(this.addresses.ValidatorTimeLock, signerOrProvider);
  }

  public defaultERC20Bridge(signerOrProvider: Signer | providers.Provider) {
    return L1ERC20BridgeFactory.connect(this.addresses.Bridges.ERC20BridgeProxy, signerOrProvider);
  }

  public defaultERC20BridgeMessageParsing(signerOrProvider: Signer | providers.Provider) {
    return ERC20BridgeMessageParsingFactory.connect(this.addresses.Bridges.ERC20BridgeMessageParsing, signerOrProvider);
  }

  public defaultWethBridge(signerOrProvider: Signer | providers.Provider) {
    return L1WethBridgeFactory.connect(this.addresses.Bridges.WethBridgeProxy, signerOrProvider);
  }

  public baseTokenContract(signerOrProvider: Signer | providers.Provider) {
    return ERC20Factory.connect(this.addresses.BaseToken, signerOrProvider);
  }

  public proxyAdminContract(signerOrProvider: Signer | providers.Provider) {
    return ProxyAdminFactory.connect(this.addresses.TransparentProxyAdmin, signerOrProvider);
  }
}
