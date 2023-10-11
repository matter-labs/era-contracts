import * as hardhat from 'hardhat';
import '@nomiclabs/hardhat-ethers';
import '@openzeppelin/hardhat-upgrades';

import { BigNumberish, ethers, providers, Signer, Wallet } from 'ethers';
import { Interface } from 'ethers/lib/utils';
import { diamondCut, DiamondCut, FacetCut, InitializeData } from './diamondCut';
import { IBridgeheadFactory } from '../typechain/IBridgeheadFactory';
import { IProofSystemFactory } from '../typechain/IProofSystemFactory';
import { IProofChainFactory } from '../typechain/IProofChainFactory';
import { getCurrentFacetCutsForAdd, getBridgeheadCurrentFacetCutsForAdd } from './diamondCut';
import { L1ERC20BridgeFactory } from '../typechain/L1ERC20BridgeFactory';
import { L1WethBridgeFactory } from '../typechain/L1WethBridgeFactory';
import { ValidatorTimelockFactory } from '../typechain/ValidatorTimelockFactory';
import { SingletonFactoryFactory } from '../typechain/SingletonFactoryFactory';
import { AllowListFactory } from '../typechain';
import { TransparentUpgradeableProxyFactory } from '../typechain/TransparentUpgradeableProxyFactory';
import { hexlify } from 'ethers/lib/utils';
import {
    hashL2Bytecode,
    getAddressFromEnv,
    getHashFromEnv,
    getNumberFromEnv,
    getTokens
} from '../scripts/utils';
import { readSystemContractsBytecode,   
         readBatchBootloaderBytecode
} from '../scripts/utils-bytecode';
import { deployViaCreate2 } from './deploy-utils';
import { IGovernanceFactory } from '../typechain/IGovernanceFactory';

let L2_BOOTLOADER_BYTECODE_HASH: string;
let L2_DEFAULT_ACCOUNT_BYTECODE_HASH: string;

export interface DeployedAddresses {
    Bridgehead: {
        BridgeheadDiamondProxy: string;
        BridgeheadDiamondInit: string;
        BridgeheadAdminFacet: string;
        BridgeheadGettersFacet: string;
        BridgeheadMailboxFacet: string;
        BridgeheadRegistryFacet: string;
        ChainImplementation: string;
        ChainProxy: string;
        ChainProxyAdmin: string;
    };
    ProofSystem: {
        ProofSystemProxy: string;
        ProofSystemImplementation: string;
        ProofSystemProxyAdmin: string;
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
        Bridgehead: {
            BridgeheadAdminFacet: getAddressFromEnv('CONTRACTS_BRIDGEHEAD_ADMIN_FACET_ADDR'),
            BridgeheadGettersFacet: getAddressFromEnv('CONTRACTS_BRIDGEHEAD_GETTERS_FACET_ADDR'),
            BridgeheadMailboxFacet: getAddressFromEnv('CONTRACTS_BRIDGEHEAD_MAILBOX_FACET_ADDR'),
            BridgeheadRegistryFacet: getAddressFromEnv('CONTRACTS_BRIDGEHEAD_REGISTRY_FACET_ADDR'),
            BridgeheadDiamondInit: getAddressFromEnv('CONTRACTS_BRIDGEHEAD_DIAMOND_INIT_ADDR'),
            BridgeheadDiamondProxy: getAddressFromEnv('CONTRACTS_BRIDGEHEAD_DIAMOND_PROXY_ADDR'),
            ChainImplementation: getAddressFromEnv('CONTRACTS_BRIDGEHEAD_CHAIN_IMPL_ADDR'),
            ChainProxy: getAddressFromEnv('CONTRACTS_BRIDGEHEAD_CHAIN_PROXY_ADDR'),
            ChainProxyAdmin: getAddressFromEnv('CONTRACTS_BRIDGEHEAD_CHAIN_PROXY_ADMIN_ADDR')
        },
        ProofSystem: {
            ProofSystemProxy: getAddressFromEnv('CONTRACTS_PROOF_SYSTEM_PROXY_ADDR'),
            ProofSystemImplementation: getAddressFromEnv('CONTRACTS_PROOF_SYSTEM_IMPL_ADDR'),
            ProofSystemProxyAdmin: getAddressFromEnv('CONTRACTS_PROOF_SYSTEM_PROXY_ADMIN_ADDR'),
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

    public async initialProofSystemProxyDiamondCut() {
        const facetCuts: FacetCut[] = Object.values(
            await getCurrentFacetCutsForAdd(
                this.addresses.ProofSystem.AdminFacet,
                this.addresses.ProofSystem.GettersFacet,
                this.addresses.ProofSystem.MailboxFacet,
                this.addresses.ProofSystem.ExecutorFacet
            )
        );

        const verifierParams = {
            recursionNodeLevelVkHash: getHashFromEnv('CONTRACTS_RECURSION_NODE_LEVEL_VK_HASH'),
            recursionLeafLevelVkHash: getHashFromEnv('CONTRACTS_RECURSION_LEAF_LEVEL_VK_HASH'),
            recursionCircuitsSetVksHash: getHashFromEnv('CONTRACTS_RECURSION_CIRCUITS_SET_VKS_HASH')
        };
        const priorityTxMaxGasLimit = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');
        const DiamondInit = new Interface(hardhat.artifacts.readArtifactSync('DiamondInit').abi);

        const diamondInitCalldata = DiamondInit.encodeFunctionData('initialize', [
            // these are set in the contract
            '0x0000000000000000000000000000000000000000000000000000000000000000',
            '0x0000000000000000000000000000000000002234',
            '0x0000000000000000000000000000000000003234',
            '0x0000000000000000000000000000000000000000000000000000000000000000',
            this.addresses.AllowList,
            this.addresses.ProofSystem.Verifier,
            verifierParams,
            L2_BOOTLOADER_BYTECODE_HASH,
            L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
            priorityTxMaxGasLimit
        ]);

        return diamondCut(facetCuts, this.addresses.ProofSystem.DiamondInit, diamondInitCalldata);
    }

    public async initialBridgeheadProxyDiamondCut() {
        const facetCuts: FacetCut[] = Object.values(
            await getBridgeheadCurrentFacetCutsForAdd(
                this.addresses.Bridgehead.BridgeheadAdminFacet,
                this.addresses.Bridgehead.BridgeheadGettersFacet,
                this.addresses.Bridgehead.BridgeheadMailboxFacet,
                this.addresses.Bridgehead.BridgeheadRegistryFacet
            )
        );

        const DiamondInit = new Interface(hardhat.artifacts.readArtifactSync('BridgeheadDiamondInit').abi);

        const diamondInitCalldata = DiamondInit.encodeFunctionData('initialize', [
            this.ownerAddress,
            this.addresses.AllowList
        ]);

        return diamondCut(facetCuts, this.addresses.Bridgehead.BridgeheadDiamondInit, diamondInitCalldata);
    }

    public async deployCreate2Factory(ethTxOptions?: ethers.providers.TransactionRequest) {
        if (this.verbose) {
            console.log('Deploying Create2 factory');
        }

        const contractFactory = await hardhat.ethers.getContractFactory('SingletonFactory', {
            signer: this.deployWallet
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
        args: any[],
        create2Salt: string,
        ethTxOptions: ethers.providers.TransactionRequest,
        libraries?: any
    ) {
        let result = await deployViaCreate2(
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
            'Governance',
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
        const contractAddress = await this.deployViaCreate2(
            'AllowList',
            [this.ownerAddress],
            create2Salt,
            ethTxOptions
        );

        if (this.verbose) {
            console.log(`CONTRACTS_L1_ALLOW_LIST_ADDR=${contractAddress}`);
        }

        this.addresses.AllowList = contractAddress;
    }

    public async deployBridgeheadChainProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        // we deploy a whole chainProxy, but we only store the admin and implementation addresses
        ethTxOptions.gasLimit ??= 10_000_000;

        const Chain = await hardhat.ethers.getContractFactory('BridgeheadChain');
        const addressOne = '0x0000000000000000000000000000000000000001';
        const instance: ethers.Contract = await hardhat.upgrades.deployProxy(Chain, [
            0,
            hardhat.ethers.constants.AddressZero,
            addressOne,
            this.addresses.AllowList
        ]);

        await instance.deployed();

        const adminAddress = await hardhat.upgrades.erc1967.getAdminAddress(instance.address);

        const implAddress = await hardhat.upgrades.erc1967.getImplementationAddress(instance.address);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHEAD_CHAIN_IMPL_ADDR=${implAddress}`);
        }

        this.addresses.Bridgehead.ChainImplementation = implAddress;

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHEAD_CHAIN_PROXY_ADMIN_ADDR=${adminAddress}`);
        }

        if (this.verbose) {
            console.log(
                `Bridgehead Chain Proxy deployed, gas used: ${(
                    await instance.deployTransaction.wait()
                ).gasUsed.toString()}`
            );
        }
        this.addresses.Bridgehead.ChainProxyAdmin = adminAddress;
    }

    public async deployBridgeheadAdminFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('BridgeheadAdminFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHEAD_ADMIN_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehead.BridgeheadAdminFacet = contractAddress;
    }

    public async deployBridgeheadGettersFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('BridgeheadGettersFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHEAD_GETTERS_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehead.BridgeheadGettersFacet = contractAddress;
    }


    public async deployBridgeheadMailboxFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('BridgeheadMailboxFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHEAD_MAILBOX_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehead.BridgeheadMailboxFacet = contractAddress;
    }

    public async deployBridgeheadRegistryFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('BridgeheadRegistryFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHEAD_REGISTRY_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehead.BridgeheadRegistryFacet = contractAddress;
    }
    public async deployBridgeheadDiamondInit(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('BridgeheadDiamondInit', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_BRIDGEHEAD_DIAMOND_INIT_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehead.BridgeheadDiamondInit = contractAddress;
    }


    public async deployProofSystemProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;

        const ProofSystem = await hardhat.ethers.getContractFactory('ProofSystem');

        const genesisBlockHash = getHashFromEnv('CONTRACTS_GENESIS_ROOT'); // TODO: confusing name
        const genesisRollupLeafIndex = getNumberFromEnv('CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX');
        const genesisBlockCommitment = getHashFromEnv('CONTRACTS_GENESIS_BLOCK_COMMITMENT');
        const priorityTxMaxGasLimit = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');

        const instance = await hardhat.upgrades.deployProxy(ProofSystem, [
            {
                bridgehead: this.addresses.Bridgehead.BridgeheadDiamondProxy,
                verifier: this.addresses.ProofSystem.Verifier,
                governor: this.ownerAddress,
                admin: this.ownerAddress,
                genesisBatchHash: genesisBlockHash,
                genesisIndexRepeatedStorageChanges: genesisRollupLeafIndex,
                genesisBatchCommitment: genesisBlockCommitment,
                allowList: this.addresses.AllowList,
                l2BootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
                l2DefaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
                priorityTxMaxGasLimit
            } as InitializeData
        ]);
        await instance.deployed();

        const implAddress = await hardhat.upgrades.erc1967.getImplementationAddress(instance.address);
        const adminAddress = await hardhat.upgrades.erc1967.getAdminAddress(instance.address);

        if (this.verbose) {
            console.log(`CONTRACTS_PROOF_SYSTEM_IMPL_ADDR=${implAddress}`);
        }

        this.addresses.ProofSystem.ProofSystemImplementation = implAddress;

        if (this.verbose) {
            console.log(`CONTRACTS_PROOF_SYSTEM_PROXY_ADDR=${instance.address}`);
        }

        this.addresses.ProofSystem.ProofSystemProxy = instance.address;

        if (this.verbose) {
            console.log(`CONTRACTS_PROOF_SYSTEM_PROXY_ADMIN_ADDR=${adminAddress}`);
        }

        if (this.verbose) {
            console.log(
                `ProofSystem Proxy deployed, gas used: ${(await instance.deployTransaction.wait()).gasUsed.toString()}`
            );
        }

        this.addresses.ProofSystem.ProofSystemProxyAdmin = adminAddress;
    }

    public async deployAdminFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('AdminFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_ADMIN_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.ProofSystem.AdminFacet = contractAddress;
    }

    public async deployMailboxFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('MailboxFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_MAILBOX_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.ProofSystem.MailboxFacet = contractAddress;
    }

    public async deployExecutorFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('ExecutorFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_EXECUTOR_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.ProofSystem.ExecutorFacet = contractAddress;
    }

    public async deployGettersFacet(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('GettersFacet', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_GETTERS_FACET_ADDR=${contractAddress}`);
        }

        this.addresses.ProofSystem.GettersFacet = contractAddress;
    }

    public async deployVerifier(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('Verifier', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_VERIFIER_ADDR=${contractAddress}`);
        }

        this.addresses.ProofSystem.Verifier = contractAddress;
    }

    public async deployERC20BridgeImplementation(
        create2Salt: string,
        ethTxOptions: ethers.providers.TransactionRequest
    ) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2(
            'L1ERC20Bridge',
            [this.addresses.Bridgehead.BridgeheadDiamondProxy, this.addresses.AllowList],
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

    public async deployWethBridgeImplementation(
        create2Salt: string,
        ethTxOptions: ethers.providers.TransactionRequest
    ) {
        const tokens = getTokens(process.env.CHAIN_ETH_NETWORK || 'localhost');
        const l1WethToken = tokens.find((token: { symbol: string }) => token.symbol == 'WETH')!.address;

        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2(
            'L1WethBridge',
            [l1WethToken, this.addresses.Bridgehead.BridgeheadDiamondProxy, this.addresses.AllowList],
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
            'TransparentUpgradeableProxy',
            [this.addresses.Bridges.WethBridgeImplementation, this.ownerAddress, '0x'],
            create2Salt,
            ethTxOptions
        );

        if (this.verbose) {
            console.log(`CONTRACTS_L1_WETH_BRIDGE_PROXY_ADDR=${contractAddress}`);
        }

        this.addresses.Bridges.WethBridgeProxy = contractAddress;
    }

    public async deployProofDiamondInit(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('DiamondInit', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_DIAMOND_INIT_ADDR=${contractAddress}`);
        }

        this.addresses.ProofSystem.DiamondInit = contractAddress;
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

        this.addresses.ProofSystem.DiamondUpgradeInit = contractAddress;
    }

    public async deployDefaultUpgrade(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;
        const contractAddress = await this.deployViaCreate2('ProofDefaultUpgrade', [], create2Salt, ethTxOptions);

        if (this.verbose) {
            console.log(`CONTRACTS_DEFAULT_UPGRADE_ADDR=${contractAddress}`);
        }

        this.addresses.ProofSystem.DefaultUpgrade = contractAddress;
    }

    // public async deployBridgeheadDiamondProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
    //     ethTxOptions.gasLimit ??= 10_000_000;

    //     const Bridgehead = await hardhat.ethers.getContractFactory('Bridgehead');
    //     const instance = await hardhat.upgrades.deployProxy(Bridgehead, [
    //         this.ownerAddress,
    //         this.addresses.AllowList
    //     ]);
    //     await instance.deployed();

    //     const implAddress = await hardhat.upgrades.erc1967.getImplementationAddress(instance.address);
    //     const adminAddress = await hardhat.upgrades.erc1967.getAdminAddress(instance.address);

    //     if (this.verbose) {
    //         console.log(`CONTRACTS_BRIDGEHEAD_IMPL_ADDR=${implAddress}`);
    //     }

    //     this.addresses.Bridgehead.BridgeheadImplementation = implAddress;

    //     if (this.verbose) {
    //         console.log(`CONTRACTS_BRIDGEHEAD_PROXY_ADDR=${instance.address}`);
    //     }

    //     this.addresses.Bridgehead.BridgeheadDiamondProxy = instance.address;

    //     if (this.verbose) {
    //         console.log(`CONTRACTS_BRIDGEHEAD_PROXY_ADMIN_ADDR=${adminAddress}`);
    //     }

    //     if (this.verbose) {
    //         console.log(
    //             `Bridgehead Proxy deployed, gas used: ${(await instance.deployTransaction.wait()).gasUsed.toString()}`
    //         );
    //     }
    //     this.addresses.Bridgehead.BridgeheadDiamondProxyAdmin = adminAddress;
    // }

    public async deployBridgeheadDiamondProxy(create2Salt: string, ethTxOptions: ethers.providers.TransactionRequest) {
        ethTxOptions.gasLimit ??= 10_000_000;

        const chainId = getNumberFromEnv('ETH_CLIENT_CHAIN_ID');
        const initialDiamondCut = await this.initialBridgeheadProxyDiamondCut();
        const contractAddress = await this.deployViaCreate2(
            'DiamondProxy',
            [chainId, initialDiamondCut],
            create2Salt,
            ethTxOptions
        );

        if (this.verbose) {
            console.log(`CONTRACTS_BRRIDGEHEAD_DIAMOND_PROXY_ADDR=${contractAddress}`);
        }

        this.addresses.Bridgehead.BridgeheadDiamondProxy = contractAddress;
    }

    public async deployBridgeheadContract(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
        nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

        // await this.deployBridgeheadChainProxy(create2Salt, { gasPrice, nonce: nonce + 0 });
        await this.deployBridgeheadDiamond(create2Salt, gasPrice, nonce  );
        nonce = await this.deployWallet.getTransactionCount();
        await this.deployBridgeheadDiamondProxy(create2Salt, { gasPrice, nonce: nonce });
    }

    public async deployBridgeheadDiamond(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
        nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

        await this.deployBridgeheadAdminFacet(create2Salt, { gasPrice, nonce: nonce + 0 });
        await this.deployBridgeheadMailboxFacet(create2Salt, { gasPrice, nonce: nonce + 1 });
        await this.deployBridgeheadGettersFacet(create2Salt, { gasPrice, nonce: nonce + 2 });
        await this.deployBridgeheadRegistryFacet(create2Salt, { gasPrice, nonce: nonce + 3 });
        await this.deployBridgeheadDiamondInit(create2Salt, { gasPrice, nonce: nonce + 4 });
    }

    public async deployProofSystemContract(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
        nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

        await this.deployProofDiamond(create2Salt, gasPrice, nonce);
        await this.deployProofSystemProxy(create2Salt, { gasPrice });
        await this.registerProofSystem();
    }

    public async deployProofDiamond(create2Salt: string, gasPrice?: BigNumberish, nonce?) {
        nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

        await this.deployExecutorFacet(create2Salt, { gasPrice, nonce: nonce });
        await this.deployAdminFacet(create2Salt, { gasPrice, nonce: nonce + 1 });
        await this.deployMailboxFacet(create2Salt, { gasPrice, nonce: nonce + 2 });
        await this.deployGettersFacet(create2Salt, { gasPrice, nonce: nonce + 3 });
        await this.deployVerifier(create2Salt, { gasPrice, nonce: nonce + 4 });
        await this.deployProofDiamondInit(create2Salt, { gasPrice, nonce: nonce + 5 });
    }

    public async registerProofSystem() {
        const bridgehead = this.bridgeheadContract(this.deployWallet);

        const tx = await bridgehead.newProofSystem(this.addresses.ProofSystem.ProofSystemProxy);

        const receipt = await tx.wait();
        if (this.verbose) {
            console.log(`Proof System registered, gas used: ${receipt.gasUsed.toString()}`);
        }
        // KL todo: ChainId is not a uint256 yet.
    }

    public async registerHyperchain(create2Salt: string, diamondCut?: DiamondCut, gasPrice?: BigNumberish, nonce?) {
        const gasLimit = 10_000_000;

        nonce = nonce ? parseInt(nonce) : await this.deployWallet.getTransactionCount();

        const bridgehead = this.bridgeheadContract(this.deployWallet);
        const proofSystem = this.proofSystemContract(this.deployWallet);

        // const inputChainId = getNumberFromEnv("CHAIN_ETH_ZKSYNC_NETWORK_ID");
        const inputChainId = 0;
        const governor = this.ownerAddress;
        const allowList = this.addresses.AllowList;
        const initialDiamondCut = diamondCut ? diamondCut : await this.initialProofSystemProxyDiamondCut();

        const tx = await bridgehead.newChain(
            inputChainId,
            this.addresses.ProofSystem.ProofSystemProxy,
            governor,
            allowList,
            initialDiamondCut,
            { gasPrice, nonce, gasLimit }
        );
        const receipt = await tx.wait();
        const chainId = receipt.logs.find((log) => log.topics[0] == bridgehead.interface.getEventTopic('NewChain'))
            .topics[1];

        const proofContractAddress =
            '0x' +
            receipt.logs
                .find((log) => log.topics[0] == proofSystem.interface.getEventTopic('NewProofChain'))
                .topics[2].slice(26);

        this.addresses.ProofSystem.DiamondProxy = proofContractAddress;

        if (this.verbose) {
            console.log(`Hyperchain registered, gas used: ${receipt.gasUsed.toString()}`);
            // KL todo: ChainId is not a uint256 yet.
            console.log(`CHAIN_ETH_ZKSYNC_NETWORK_ID=${parseInt(chainId, 16)}`);
            console.log(`CONTRACTS_DIAMOND_PROXY_ADDR=${proofContractAddress}`);
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
            [this.ownerAddress, this.addresses.ProofSystem.DiamondProxy, executionDelay, validatorAddress],
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
        return TransparentUpgradeableProxyFactory.connect(address, signerOrProvider);
    }

    public create2FactoryContract(signerOrProvider: Signer | providers.Provider) {
        return SingletonFactoryFactory.connect(this.addresses.Create2Factory, signerOrProvider);
    }

    public bridgeheadContract(signerOrProvider: Signer | providers.Provider) {
        return IBridgeheadFactory.connect(this.addresses.Bridgehead.BridgeheadDiamondProxy, signerOrProvider);
    }

    public proofSystemContract(signerOrProvider: Signer | providers.Provider) {
        return IProofSystemFactory.connect(this.addresses.ProofSystem.ProofSystemProxy, signerOrProvider);
    }

    public proofChainContract(signerOrProvider: Signer | providers.Provider) {
        return IProofChainFactory.connect(this.addresses.ProofSystem.DiamondProxy, signerOrProvider);
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
