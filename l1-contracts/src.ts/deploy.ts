import * as hardhat from "hardhat";
import "@nomiclabs/hardhat-ethers";

import type { BigNumberish, providers, Signer, Wallet } from "ethers";
import { ethers } from "ethers";
import { Interface, hexlify } from "ethers/lib/utils";
import { diamondCut, getCurrentFacetCutsForAdd } from "./diamondCut";
import { IZkSyncFactory } from "../typechain/IZkSyncFactory";
import { L1ERC20BridgeFactory } from "../typechain/L1ERC20BridgeFactory";
import { L1WethBridgeFactory } from "../typechain/L1WethBridgeFactory";
import { ValidatorTimelockFactory } from "../typechain/ValidatorTimelockFactory";
import { SingletonFactoryFactory } from "../typechain/SingletonFactoryFactory";
import { TransparentUpgradeableProxyFactory } from "../typechain/TransparentUpgradeableProxyFactory";
import {
  readSystemContractsBytecode,
  hashL2Bytecode,
  getAddressFromEnv,
  getHashFromEnv,
  getNumberFromEnv,
  readBatchBootloaderBytecode,
  getTokens,
} from "../scripts/utils";
import { deployViaCreate2 } from "./deploy-utils";
import { IGovernanceFactory } from "../typechain/IGovernanceFactory";

const L2_BOOTLOADER_BYTECODE_HASH = hexlify(hashL2Bytecode(readBatchBootloaderBytecode()));
const L2_DEFAULT_ACCOUNT_BYTECODE_HASH = hexlify(hashL2Bytecode(readSystemContractsBytecode("DefaultAccount")));

export interface DeployedAddresses {
  ZkSync: {
    MailboxFacet: string;
    AdminFacet: string;
    ExecutorFacet: string;
    GettersFacet: string;
    Verifier: string;
    DiamondInit: string;
    DiamondUpgradeInit: string;
    DefaultUpgrade: string;
    DiamondProxy: string;
  };
  Bridges: {
    ERC20BridgeImplementation: string;
    ERC20BridgeProxy: string;
    WethBridgeImplementation: string;
    WethBridgeProxy: string;
  };
  Governance: string;
  ValidatorTimeLock: string;
  Create2Factory: string;
}

export interface DeployerConfig {
  deployWallet: Wallet;
  ownerAddress?: string;
  verbose?: boolean;
}

export function deployedAddressesFromEnv(): DeployedAddresses {
  return {
    ZkSync: {
      MailboxFacet: getAddressFromEnv("CONTRACTS_MAILBOX_FACET_ADDR"),
      AdminFacet: getAddressFromEnv("CONTRACTS_ADMIN_FACET_ADDR"),
      ExecutorFacet: getAddressFromEnv("CONTRACTS_EXECUTOR_FACET_ADDR"),
      GettersFacet: getAddressFromEnv("CONTRACTS_GETTERS_FACET_ADDR"),
      DiamondInit: getAddressFromEnv("CONTRACTS_DIAMOND_INIT_ADDR"),
      DiamondUpgradeInit: getAddressFromEnv("CONTRACTS_DIAMOND_UPGRADE_INIT_ADDR"),
      DefaultUpgrade: getAddressFromEnv("CONTRACTS_DEFAULT_UPGRADE_ADDR"),
      DiamondProxy: getAddressFromEnv("CONTRACTS_DIAMOND_PROXY_ADDR"),
      Verifier: getAddressFromEnv("CONTRACTS_VERIFIER_ADDR"),
    },
    Bridges: {
      ERC20BridgeImplementation: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_IMPL_ADDR"),
      ERC20BridgeProxy: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_PROXY_ADDR"),
      WethBridgeImplementation: getAddressFromEnv("CONTRACTS_L1_WETH_BRIDGE_IMPL_ADDR"),
      WethBridgeProxy: getAddressFromEnv("CONTRACTS_L1_WETH_BRIDGE_PROXY_ADDR"),
    },
    Create2Factory: getAddressFromEnv("CONTRACTS_CREATE2_FACTORY_ADDR"),
    ValidatorTimeLock: getAddressFromEnv("CONTRACTS_VALIDATOR_TIMELOCK_ADDR"),
    Governance: getAddressFromEnv("CONTRACTS_GOVERNANCE_ADDR"),
  };
}

export class Deployer {
  public addresses: DeployedAddresses;
  private deployWallet: Wallet;
  private verbose: boolean;
  private ownerAddress: string;

  constructor(config: DeployerConfig) {
    this.deployWallet = config.deployWallet;
    this.verbose = config.verbose != null ? config.verbose : false;
    this.addresses = deployedAddressesFromEnv();
    this.ownerAddress = config.ownerAddress != null ? config.ownerAddress : this.deployWallet.address;
  }

  public async initialProxyDiamondCut() {
    const facetCuts = Object.values(
      await getCurrentFacetCutsForAdd(
        this.addresses.ZkSync.AdminFacet,
        this.addresses.ZkSync.GettersFacet,
        this.addresses.ZkSync.MailboxFacet,
        this.addresses.ZkSync.ExecutorFacet
      )
    );
    const genesisBatchHash = getHashFromEnv("CONTRACTS_GENESIS_ROOT"); // TODO: confusing name
    const genesisIndexRepeatedStorageChanges = getNumberFromEnv("CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX");
    const genesisBatchCommitment = getHashFromEnv("CONTRACTS_GENESIS_BATCH_COMMITMENT");

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
    const initialProtocolVersion = getNumberFromEnv("CONTRACTS_INITIAL_PROTOCOL_VERSION");
    const DiamondInit = new Interface(hardhat.artifacts.readArtifactSync("DiamondInit").abi);

    const diamondInitCalldata = DiamondInit.encodeFunctionData("initialize", [
      {
        verifier: this.addresses.ZkSync.Verifier,
        governor: this.ownerAddress,
        admin: this.ownerAddress,
        genesisBatchHash,
        genesisIndexRepeatedStorageChanges,
        genesisBatchCommitment,
        verifierParams,
        zkPorterIsAvailable: false,
        l2BootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
        l2DefaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
        priorityTxMaxGasLimit,
        initialProtocolVersion,
      },
    ]);

    // @ts-ignore
    return diamondCut(facetCuts, this.addresses.ZkSync.DiamondInit, diamondInitCalldata);
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

  public async deployMailboxFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("MailboxFacet", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_MAILBOX_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.ZkSync.MailboxFacet = contractAddress;
  }

  public async deployAdminFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("AdminFacet", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_ADMIN_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.ZkSync.AdminFacet = contractAddress;
  }

  public async deployExecutorFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("ExecutorFacet", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_EXECUTOR_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.ZkSync.ExecutorFacet = contractAddress;
  }

  public async deployGettersFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("GettersFacet", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_GETTERS_FACET_ADDR=${contractAddress}`);
    }

    this.addresses.ZkSync.GettersFacet = contractAddress;
  }

  public async deployVerifier(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("Verifier", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_VERIFIER_ADDR=${contractAddress}`);
    }

    this.addresses.ZkSync.Verifier = contractAddress;
  }

  public async deployERC20BridgeImplementation(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2(
      "L1ERC20Bridge",
      [this.addresses.ZkSync.DiamondProxy],
      create2Salt,
      ethTxOptions
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
      [this.addresses.Bridges.ERC20BridgeImplementation, this.ownerAddress, "0x"],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_ERC20_BRIDGE_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.ERC20BridgeProxy = contractAddress;
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
      [l1WethToken, this.addresses.ZkSync.DiamondProxy],
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
      [this.addresses.Bridges.WethBridgeImplementation, this.ownerAddress, "0x"],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_L1_WETH_BRIDGE_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.Bridges.WethBridgeProxy = contractAddress;
  }

  public async deployDiamondInit(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("DiamondInit", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_DIAMOND_INIT_ADDR=${contractAddress}`);
    }

    this.addresses.ZkSync.DiamondInit = contractAddress;
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

    this.addresses.ZkSync.DiamondUpgradeInit = contractAddress;
  }

  public async deployDefaultUpgrade(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("DefaultUpgrade", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_DEFAULT_UPGRADE_ADDR=${contractAddress}`);
    }

    this.addresses.ZkSync.DefaultUpgrade = contractAddress;
  }

  public async deployDiamondProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;

    const chainId = getNumberFromEnv("ETH_CLIENT_CHAIN_ID");
    const initialDiamondCut = await this.initialProxyDiamondCut();
    const contractAddress = await this.deployViaCreate2(
      "DiamondProxy",
      [chainId, initialDiamondCut],
      create2Salt,
      ethTxOptions
    );

    if (this.verbose) {
      console.log(`CONTRACTS_DIAMOND_PROXY_ADDR=${contractAddress}`);
    }

    this.addresses.ZkSync.DiamondProxy = contractAddress;
  }

  public async deployZkSyncContract(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    // deploy zkSync contract
    const independentZkSyncDeployPromises = [
      this.deployMailboxFacet(create2Salt, { gasPrice, nonce }),
      this.deployExecutorFacet(create2Salt, { gasPrice, nonce: nonce + 1 }),
      this.deployAdminFacet(create2Salt, { gasPrice, nonce: nonce + 2 }),
      this.deployGettersFacet(create2Salt, { gasPrice, nonce: nonce + 3 }),
      this.deployDiamondInit(create2Salt, { gasPrice, nonce: nonce + 4 }),
    ];
    await Promise.all(independentZkSyncDeployPromises);
    nonce += 5;

    await this.deployDiamondProxy(create2Salt, { gasPrice, nonce });
  }

  public async deployBridgeContracts(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployERC20BridgeImplementation(create2Salt, { gasPrice, nonce: nonce });
    await this.deployERC20BridgeProxy(create2Salt, { gasPrice, nonce: nonce + 1 });
  }

  public async deployWethBridgeContracts(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
    nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

    await this.deployWethBridgeImplementation(create2Salt, { gasPrice, nonce: nonce++ });
    await this.deployWethBridgeProxy(create2Salt, { gasPrice, nonce: nonce++ });
  }

  public async deployValidatorTimelock(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const executionDelay = getNumberFromEnv("CONTRACTS_VALIDATOR_TIMELOCK_EXECUTION_DELAY");
    const validatorAddress = getAddressFromEnv("ETH_SENDER_SENDER_OPERATOR_COMMIT_ETH_ADDR");
    const contractAddress = await this.deployViaCreate2(
      "ValidatorTimelock",
      [this.ownerAddress, this.addresses.ZkSync.DiamondProxy, executionDelay, validatorAddress],
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
    return TransparentUpgradeableProxyFactory.connect(address, signerOrProvider);
  }

  public create2FactoryContract(signerOrProvider: Signer | providers.Provider) {
    return SingletonFactoryFactory.connect(this.addresses.Create2Factory, signerOrProvider);
  }

  public governanceContract(signerOrProvider: Signer | providers.Provider) {
    return IGovernanceFactory.connect(this.addresses.Governance, signerOrProvider);
  }

  public zkSyncContract(signerOrProvider: Signer | providers.Provider) {
    return IZkSyncFactory.connect(this.addresses.ZkSync.DiamondProxy, signerOrProvider);
  }

  public validatorTimelock(signerOrProvider: Signer | providers.Provider) {
    return ValidatorTimelockFactory.connect(this.addresses.ValidatorTimeLock, signerOrProvider);
  }

  public defaultERC20Bridge(signerOrProvider: Signer | providers.Provider) {
    return L1ERC20BridgeFactory.connect(this.addresses.Bridges.ERC20BridgeProxy, signerOrProvider);
  }

  public defaultWethBridge(signerOrProvider: Signer | providers.Provider) {
    return L1WethBridgeFactory.connect(this.addresses.Bridges.WethBridgeProxy, signerOrProvider);
  }
}
