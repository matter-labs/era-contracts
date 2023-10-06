import { Provider, Contract, Wallet } from 'zksync-web3';
import { Deployer } from '@matterlabs/hardhat-zksync-deploy';
import { readYulBytecode } from '../../scripts/utils';
import { ethers, network } from 'hardhat';
import { BytesLike } from 'ethers';
import * as hre from 'hardhat';
import * as zksync from 'zksync-web3';
import { ZkSyncArtifact } from '@matterlabs/hardhat-zksync-deploy/dist/types';
import { DEPLOYER_SYSTEM_CONTRACT_ADDRESS } from './constants';
import { ContractDeployer__factory } from '../../typechain-types';
import { Language } from '../../scripts/constants';

const RICH_WALLETS = [
    {
        address: '0x36615Cf349d7F6344891B1e7CA7C72883F5dc049',
        privateKey: '0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110'
    },
    {
        address: '0xa61464658AfeAf65CccaaFD3a512b69A83B77618',
        privateKey: '0xac1e735be8536c6534bb4f17f06f6afc73b2b5ba84ac2cfb12f7461b20c0bbe3'
    },
    {
        address: '0x0D43eB5B8a47bA8900d84AA36656c92024e9772e',
        privateKey: '0xd293c684d884d56f8d6abd64fc76757d3664904e309a0645baf8522ab6366d9e'
    },
    {
        address: '0xA13c10C0D5bd6f79041B9835c63f91de35A15883',
        privateKey: '0x850683b40d4a740aa6e745f889a6fdc8327be76e122f5aba645a5b02d0248db8'
    }
];

export const provider = new Provider((hre.network.config as any).url);

const wallet = new Wallet(RICH_WALLETS[0].privateKey, provider);
const deployer = new Deployer(hre, wallet);

export async function callFallback(contract: Contract, data: string) {
    // `eth_Call` revert is not parsed by ethers, so we send
    // transaction to catch the error and use `eth_Call` to the return data.
    await contract.fallback({ data });
    return contract.provider.call({
        to: contract.address,
        data
    });
}

export function getWallets(): Wallet[] {
    let wallets = [];
    for (let i = 0; i < RICH_WALLETS.length; i++) {
        wallets[i] = new Wallet(RICH_WALLETS[i].privateKey, provider);
    }
    return wallets;
}

export async function loadArtifact(name: string): Promise<ZkSyncArtifact> {
    return await deployer.loadArtifact(name);
}

export async function deployContract(name: string, constructorArguments?: any[] | undefined): Promise<Contract> {
    const artifact = await loadArtifact(name);
    return await deployer.deploy(artifact, constructorArguments);
}

export async function deployContractYul(codeName: string, path: string): Promise<Contract> {
    const bytecode = readYulBytecode({
        codeName,
        path,
        lang: Language.Yul,
        address: '0x0000000000000000000000000000000000000000'
    });
    return await deployer.deploy(
        {
            bytecode,
            factoryDeps: {},
            sourceMapping: '',
            _format: '',
            contractName: '',
            sourceName: '',
            abi: [],
            deployedBytecode: bytecode,
            linkReferences: {},
            deployedLinkReferences: {}
        },
        []
    );
}

export async function publishBytecode(bytecode: BytesLike) {
    await wallet.sendTransaction({
        type: 113,
        to: ethers.constants.AddressZero,
        data: '0x',
        customData: {
            factoryDeps: [bytecode],
            gasPerPubdata: 50000
        }
    });
}

export async function getCode(address: string): Promise<string> {
    return await provider.getCode(address);
}

// Force deploy bytecode on the address
export async function setCode(address: string, bytecode: BytesLike) {
    // TODO: think about factoryDeps with eth_sendTransaction
    try {
        // publish bytecode in a separate tx
        await publishBytecode(bytecode);
    } catch {}

    await network.provider.request({
        method: 'hardhat_impersonateAccount',
        params: [DEPLOYER_SYSTEM_CONTRACT_ADDRESS]
    });

    const deployerAccount = await ethers.getSigner(DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
    const deployerContract = ContractDeployer__factory.connect(DEPLOYER_SYSTEM_CONTRACT_ADDRESS, deployerAccount);

    const deployment = {
        bytecodeHash: zksync.utils.hashBytecode(bytecode),
        newAddress: address,
        callConstructor: false,
        value: 0,
        input: '0x'
    };
    await deployerContract.forceDeployOnAddress(deployment, ethers.constants.AddressZero);

    await network.provider.request({
        method: 'hardhat_stopImpersonatingAccount',
        params: [DEPLOYER_SYSTEM_CONTRACT_ADDRESS]
    });
}
