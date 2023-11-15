import * as hardhat from 'hardhat';
import '@nomiclabs/hardhat-ethers';
import '@openzeppelin/hardhat-upgrades';

import { BigNumberish, ethers, providers, Signer, Wallet } from 'ethers';
import { Interface } from 'ethers/lib/utils';
import { diamondCut, FacetCut } from './diamondCut';
import { IBridgehubFactory } from '../typechain/IBridgehubFactory';
import { IStateTransitionFactory } from '../typechain/IStateTransitionFactory';
import { IStateTransitionChainFactory } from '../typechain/IStateTransitionChainFactory';
import { getCurrentFacetCutsForAdd, getBridgehubCurrentFacetCutsForAdd } from './diamondCut';
import { L1ERC20BridgeFactory } from '../typechain/L1ERC20BridgeFactory';
import { L1WethBridgeFactory } from '../typechain/L1WethBridgeFactory';
import { ValidatorTimelockFactory } from '../typechain/ValidatorTimelockFactory';
import { SingletonFactoryFactory } from '../typechain/SingletonFactoryFactory';
import { AllowListFactory } from '../typechain';
import { ITransparentUpgradeableProxyFactory } from '../typechain/ITransparentUpgradeableProxyFactory';
import { hexlify } from 'ethers/lib/utils';
import {
    hashL2Bytecode,
    getAddressFromEnv,
    getHashFromEnv,
    getNumberFromEnv,
    readSystemContractsBytecode,
    readBatchBootloaderBytecode,
    getTokens
} from '../scripts/utils';

import { deployViaCreate2 } from './deploy-utils';
import { IGovernanceFactory } from '../typechain/IGovernanceFactory';

let L2_BOOTLOADER_BYTECODE_HASH: string;
let L2_DEFAULT_ACCOUNT_BYTECODE_HASH: string;

export interface DeployedAddresses {
    Bridgehub: {
        BridgehubDiamondProxy: string;
        BridgehubDiamondInit: string;
        BridgehubAdminFacet: string;
        BridgehubGettersFacet: string;
        BridgehubMailboxFacet: string;
        BridgehubRegistryFacet: string;
    };
    StateTransition: {
        StateTransitionProxy: string;
        StateTransitionImplementation: string;
        StateTransitionProxyAdmin: string;
        Verifier: string;
        AdminFacet: string;
        MailboxFacet: string;
        ExecutorFacet: string;
        GettersFacet: string;
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
    AllowList: string;
    ValidatorTimeLock: string;
    Create2Factory: string;
}

export interface DeployerConfig {
    deployWallet: Wallet;
    ownerAddress?: string;
    verbose?: boolean;
    addresses?: DeployedAddresses;
    bootloaderBytecodeHash?: string;
    defaultAccountBytecodeHash?: string;
}

export function deployedAddressesFromEnv(): DeployedAddresses {
    return {
        Bridgehub: {
            BridgehubAdminFacet: getAddressFromEnv('CONTRACTS_BRIDGEHUB_ADMIN_FACET_ADDR'),
            BridgehubGettersFacet: getAddressFromEnv('CONTRACTS_BRIDGEHUB_GETTERS_FACET_ADDR'),
            BridgehubMailboxFacet: getAddressFromEnv('CONTRACTS_BRIDGEHUB_MAILBOX_FACET_ADDR'),
            BridgehubRegistryFacet: getAddressFromEnv('CONTRACTS_BRIDGEHUB_REGISTRY_FACET_ADDR'),
            BridgehubDiamondInit: getAddressFromEnv('CONTRACTS_BRIDGEHUB_DIAMOND_INIT_ADDR'),
            BridgehubDiamondProxy: getAddressFromEnv('CONTRACTS_BRIDGEHUB_DIAMOND_PROXY_ADDR')
        },
        StateTransition: {
            StateTransitionProxy: getAddressFromEnv('CONTRACTS_STATE_TRANSITION_PROXY_ADDR'),
            StateTransitionImplementation: getAddressFromEnv('CONTRACTS_STATE_TRANSITION_IMPL_ADDR'),
            StateTransitionProxyAdmin: getAddressFromEnv('CONTRACTS_STATE_TRANSITION_PROXY_ADMIN_ADDR'),
            Verifier: getAddressFromEnv('CONTRACTS_VERIFIER_ADDR'),
            AdminFacet: getAddressFromEnv('CONTRACTS_ADMIN_FACET_ADDR'),
            MailboxFacet: getAddressFromEnv('CONTRACTS_MAILBOX_FACET_ADDR'),
            ExecutorFacet: getAddressFromEnv('CONTRACTS_EXECUTOR_FACET_ADDR'),
            GettersFacet: getAddressFromEnv('CONTRACTS_GETTERS_FACET_ADDR'),
            DiamondInit: getAddressFromEnv('CONTRACTS_DIAMOND_INIT_ADDR'),
            DiamondUpgradeInit: getAddressFromEnv('CONTRACTS_DIAMOND_UPGRADE_INIT_ADDR'),
            DefaultUpgrade: getAddressFromEnv('CONTRACTS_DEFAULT_UPGRADE_ADDR'),
            DiamondProxy: getAddressFromEnv('CONTRACTS_DIAMOND_PROXY_ADDR')
        },
        Bridges: {
            ERC20BridgeImplementation: getAddressFromEnv('CONTRACTS_L1_ERC20_BRIDGE_IMPL_ADDR'),
            ERC20BridgeProxy: getAddressFromEnv('CONTRACTS_L1_ERC20_BRIDGE_PROXY_ADDR'),
            WethBridgeImplementation: getAddressFromEnv('CONTRACTS_L1_WETH_BRIDGE_IMPL_ADDR'),
            WethBridgeProxy: getAddressFromEnv('CONTRACTS_L1_WETH_BRIDGE_PROXY_ADDR')
        },
        AllowList: getAddressFromEnv('CONTRACTS_L1_ALLOW_LIST_ADDR'),
        Create2Factory: getAddressFromEnv('CONTRACTS_CREATE2_FACTORY_ADDR'),
        ValidatorTimeLock: getAddressFromEnv('CONTRACTS_VALIDATOR_TIMELOCK_ADDR'),
        Governance: getAddressFromEnv('CONTRACTS_GOVERNANCE_ADDR')
    };
}

export class Deployer {
    public addresses: DeployedAddresses;
    private deployWallet: Wallet;
    private verbose: boolean;
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
            : hexlify(hashL2Bytecode(readSystemContractsBytecode('DefaultAccount')));
        this.ownerAddress = config.ownerAddress != null ? config.ownerAddress : this.deployWallet.address;
    }

    public async initialStateTransitionChainDiamondCut(extraFacets?: FacetCut[]) {
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
        const priorityTxMaxGasLimit = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');
        const DiamondInit = new Interface(hardhat.artifacts.readArtifactSync('DiamondInit').abi);

        const diamondInitCalldata = DiamondInit.encodeFunctionData('initialize', [
            // these first 4 values are set in the contract
            {
                chainId: '0x0000000000000000000000000000000000000000000000000000000000000000',
                bridgehub: '0x0000000000000000000000000000000000001234',
                stateTransition: '0x0000000000000000000000000000000000002234',
                protocolVersion: '0x0000000000000000000000000000000000002234',
                governor: '0x0000000000000000000000000000000000003234',
                admin: '0x0000000000000000000000000000000000004234',
                storedBatchZero: '0x0000000000000000000000000000000000000000000000000000000000000000',
                allowList: this.addresses.AllowList,
                verifier: this.addresses.StateTransition.Verifier,
                verifierParams,
                l2BootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
                l2DefaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
                priorityTxMaxGasLimit
            }
        ]);

        return diamondCut(facetCuts, this.addresses.StateTransition.DiamondInit, diamondInitCalldata);
    }

    public async initialBridgehubProxyDiamondCut() {
        const facetCuts: FacetCut[] = Object.values(
            await getBridgehubCurrentFacetCutsForAdd(
                this.addresses.Bridgehub.BridgehubAdminFacet,
                this.addresses.Bridgehub.BridgehubGettersFacet,
                this.addresses.Bridgehub.BridgehubMailboxFacet,
                this.addresses.Bridgehub.BridgehubRegistryFacet
            )
        );

        const DiamondInit = new Interface(hardhat.artifacts.readArtifactSync('BridgehubDiamondInit').abi);

        const diamondInitCalldata = DiamondInit.encodeFunctionData('initialize', [
            this.ownerAddress,
            this.addresses.AllowList
        ]);

        return diamondCut(facetCuts, this.addresses.Bridgehub.BridgehubDiamondInit, diamondInitCalldata);
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

  public async deployAllowList(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("AllowList", [this.ownerAddress], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_L1_ALLOW_LIST_ADDR=${contractAddress}`);
    }

    this.addresses.AllowList = contractAddress;
  }

    public async deployBridgehubAdminFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('BridgehubAdminFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHUB_ADMIN_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehub.BridgehubAdminFacet = contractAddress;
    }

    public async deployBridgehubGettersFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('BridgehubGettersFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHUB_GETTERS_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehub.BridgehubGettersFacet = contractAddress;
    }

    public async deployBridgehubMailboxFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('BridgehubMailboxFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHUB_MAILBOX_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehub.BridgehubMailboxFacet = contractAddress;
    }

    public async deployBridgehubRegistryFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('BridgehubRegistryFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHUB_REGISTRY_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehub.BridgehubRegistryFacet = contractAddress;
    }
    public async deployBridgehubDiamondInit(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('BridgehubDiamondInit', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHUB_DIAMOND_INIT_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehub.BridgehubDiamondInit = contractAddress;
    }

    public async deployStateTransitionProxy(
        create2Salt: string,
        ethTxOptions: ethers.providers.TransactionRequest,
        extraFacets?: FacetCut[]
    ) {
        ethTxOptions.gasLimit ??= 10_000_000;

        const StateTransition = await hardhat.ethers.getContractFactory('StateTransition');

        const genesisBlockHash = getHashFromEnv('CONTRACTS_GENESIS_ROOT'); // TODO: confusing name
        const genesisRollupLeafIndex = getNumberFromEnv('CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX');
        const genesisBlockCommitment = getHashFromEnv('CONTRACTS_GENESIS_BATCH_COMMITMENT');
        const diamondCut = await this.initialStateTransitionChainDiamondCut(extraFacets);
        const protocolVersion = getNumberFromEnv('CONTRACTS_LATEST_PROTOCOL_VERSION');

        const instance = await hardhat.upgrades.deployProxy(StateTransition, [
            {
                bridgehub: this.addresses.Bridgehub.BridgehubDiamondProxy,
                governor: this.ownerAddress,
                diamondInit: this.addresses.StateTransition.DiamondInit,
                genesisBatchHash: genesisBlockHash,
                genesisIndexRepeatedStorageChanges: genesisRollupLeafIndex,
                genesisBatchCommitment: genesisBlockCommitment,
                diamondCut,
                protocolVersion
            }
        ]);
        await instance.deployed();

        const implAddress = await hardhat.upgrades.erc1967.getImplementationAddress(instance.address);
        const adminAddress = await hardhat.upgrades.erc1967.getAdminAddress(instance.address);

        if (this.verbose) {
            console.log(`CONTRACTS_STATE_TRANSITION_IMPL_ADDR=${implAddress}`);
        }

        this.addresses.StateTransition.StateTransitionImplementation = implAddress;

        if (this.verbose) {
            console.log(`CONTRACTS_STATE_TRANSITION_PROXY_ADDR=${instance.address}`);
        }

        this.addresses.StateTransition.StateTransitionProxy = instance.address;

        if (this.verbose) {
            console.log(`CONTRACTS_STATE_TRANSITION_PROXY_ADMIN_ADDR=${adminAddress}`);
        }

        if (this.verbose) {
            console.log(
                `StateTransition Proxy deployed, gas used: ${(
                    await instance.deployTransaction.wait()
                ).gasUsed.toString()}`
            );
        }

        this.addresses.StateTransition.StateTransitionProxyAdmin = adminAddress;
    }

    
    public async deployAdminFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('AdminFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_ADMIN_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.StateTransition.AdminFacet = contractAddress;
    }

    public async deployMailboxFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('MailboxFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_MAILBOX_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.StateTransition.MailboxFacet = contractAddress;
    }

    public async deployExecutorFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('ExecutorFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_EXECUTOR_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.StateTransition.ExecutorFacet = contractAddress;
    }

    public async deployGettersFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('GettersFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_GETTERS_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.StateTransition.GettersFacet = contractAddress;
    }

    public async deployVerifier(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('Verifier', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_VERIFIER_ADDR=${contractAddress}`);
        }

        this.addresses.StateTransition.Verifier = contractAddress;
    }


    public async deployERC20BridgeImplementation(
        create2Salt: string,
        ethTxOptions: ethers.providers.TransactionRequest
    ) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2(
            'L1ERC20Bridge',
            [this.addresses.Bridgehub.BridgehubDiamondProxy, this.addresses.AllowList],
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
            'TransparentUpgradeableProxy',
            [this.addresses.Bridges.ERC20BridgeImplementation, this.ownerAddress, '0x'],
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
        const contractAddress = await this.deployViaCreate2('WETH9', [], create2Salt, ethTxOptions);

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
      [l1WethToken, this.addresses.StateTransition.DiamondProxy, this.addresses.AllowList],
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

  public async deployStateTransitionDiamondInit(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    ethTxOptions.gasLimit ??= 10_000_000;
    const contractAddress = await this.deployViaCreate2("DiamondInit", [], create2Salt, ethTxOptions);

    if (this.verbose) {
      console.log(`CONTRACTS_STATE_TRANSITION_DIAMOND_INIT_ADDR=${contractAddress}`);
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

    public async deployBridgehubDiamondProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;

        const chainId = getNumberFromEnv('ETH_CLIENT_CHAIN_ID');
        const initialDiamondCut = await this.initialBridgehubProxyDiamondCut();
        const contractAddress = await this.deployViaCreate2(
            'DiamondProxy',
            [chainId, initialDiamondCut],
            create2Salt,
            ethTxOptions
        );

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHUB_DIAMOND_PROXY_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehub.BridgehubDiamondProxy = contractAddress;
    }

    public async deployBridgehubContract(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
        nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

        // await this.deployBridgehubChainProxy(create2Salt, { gasPrice, nonce: nonce + 0 });
        await this.deployBridgehubDiamond(create2Salt, gasPrice, nonce);
        nonce = await this.deployWallet.getTransactionCount();
        await this.deployBridgehubDiamondProxy(create2Salt, { gasPrice, nonce: nonce });
    }

    public async deployBridgehubDiamond(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
        nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

        await this.deployBridgehubAdminFacet(create2Salt, { gasPrice, nonce: nonce + 0 });
        await this.deployBridgehubMailboxFacet(create2Salt, { gasPrice, nonce: nonce + 1 });
        await this.deployBridgehubGettersFacet(create2Salt, { gasPrice, nonce: nonce + 2 });
        await this.deployBridgehubRegistryFacet(create2Salt, { gasPrice, nonce: nonce + 3 });
        await this.deployBridgehubDiamondInit(create2Salt, { gasPrice, nonce: nonce + 4 });
    }

    public async deployStateTransitionContract(
        create2Salt: string,
        extraFacets?: FacetCut[],
        gasPrice?: BigNumberish,
        nonce?
    ) {
        nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

        await this.deployStateTransitionDiamond(create2Salt, gasPrice, nonce);
        await this.deployStateTransitionProxy(create2Salt, { gasPrice }, extraFacets);
        await this.registerStateTransition();
    }

    public async deployStateTransitionDiamond(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
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

        const tx = await bridgehub.newStateTransition(this.addresses.StateTransition.StateTransitionProxy);

        const receipt = await tx.wait();
        if (this.verbose) {
            console.log(`StateTransition System registered, gas used: ${receipt.gasUsed.toString()}`);
        }
        // KL todo: ChainId is not a uint256 yet.
    }

    public async registerHyperchain(create2Salt: string, extraFacets?: FacetCut[], gasPrice?: BigNumberish, nonce?) {
        const gasLimit = 10_000_000;

        nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

        const bridgehub = this.bridgehubContract(this.deployWallet);
        const stateTransition = this.stateTransitionContract(this.deployWallet);

        // const inputChainId = getNumberFromEnv("CHAIN_ETH_ZKSYNC_NETWORK_ID");
        const inputChainId = 0;
        const governor = this.ownerAddress;
        const initialDiamondCut = await this.initialStateTransitionChainDiamondCut(extraFacets);

        const tx = await bridgehub.newChain(inputChainId, this.addresses.StateTransition.StateTransitionProxy, Date.now(), {
            gasPrice,
            nonce,
            gasLimit
        });
        const receipt = await tx.wait();
        const chainId = receipt.logs.find((log) => log.topics[0] == bridgehub.interface.getEventTopic('NewChain'))
            .topics[1];

        nonce++;
        const tx2 = await stateTransition.newChain(chainId, governor, initialDiamondCut, { gasPrice, nonce, gasLimit });
        const receipt2 = await tx2.wait();
        const diamondProxyAddress =
            '0x' +
            receipt2.logs
                .find((log) => log.topics[0] == stateTransition.interface.getEventTopic('StateTransitionNewChain'))
                .topics[2].slice(26);

        this.addresses.StateTransition.DiamondProxy = diamondProxyAddress;

        if (this.verbose) {
            console.log(
                `Hyperchain registered, gas used: ${receipt.gasUsed.toString()} and ${receipt2.gasUsed.toString()}`
            );
            console.log(
                `Hyperchain registration tx hash: ${receipt.transactionHash}`
            );
            // 
            // KL todo: ChainId is not a uint256 yet.
            console.log(`CHAIN_ETH_ZKSYNC_NETWORK_ID=${parseInt(chainId, 16)}`);
            console.log(`CONTRACTS_DIAMOND_PROXY_ADDR=${diamondProxyAddress}`);
        }
        this.chainId = parseInt(chainId, 16);
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
        const executionDelay = getNumberFromEnv('CONTRACTS_VALIDATOR_TIMELOCK_EXECUTION_DELAY');
        const validatorAddress = getAddressFromEnv('ETH_SENDER_SENDER_OPERATOR_COMMIT_ETH_ADDR');
        const contractAddress = await this.deployViaCreate2(
            'ValidatorTimelock',
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
        const contractAddress = await this.deployViaCreate2('Multicall3', [], create2Salt, ethTxOptions);

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
        return IBridgehubFactory.connect(this.addresses.Bridgehub.BridgehubDiamondProxy, signerOrProvider);
    }

    public stateTransitionContract(signerOrProvider: Signer | providers.Provider) {
        return IStateTransitionFactory.connect(this.addresses.StateTransition.StateTransitionProxy, signerOrProvider);
    }

    public stateTransitionChainContract(signerOrProvider: Signer | providers.Provider) {
        return IStateTransitionChainFactory.connect(this.addresses.StateTransition.DiamondProxy, signerOrProvider);
    }

    public governanceContract(signerOrProvider: Signer | providers.Provider) {
        return IGovernanceFactory.connect(this.addresses.Governance, signerOrProvider);
    }

    public validatorTimelock(signerOrProvider: Signer | providers.Provider) {
        return ValidatorTimelockFactory.connect(this.addresses.ValidatorTimeLock, signerOrProvider);
    }

    public l1AllowList(signerOrProvider: Signer | providers.Provider) {
        return AllowListFactory.connect(this.addresses.AllowList, signerOrProvider);
    }

    public defaultERC20Bridge(signerOrProvider: Signer | providers.Provider) {
        return L1ERC20BridgeFactory.connect(this.addresses.Bridges.ERC20BridgeProxy, signerOrProvider);
    }

    public defaultWethBridge(signerOrProvider: Signer | providers.Provider) {
        return L1WethBridgeFactory.connect(this.addresses.Bridges.WethBridgeProxy, signerOrProvider);
    }
}
