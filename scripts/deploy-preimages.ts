import * as hre from 'hardhat';

import { Command } from 'commander';
import {Provider, Wallet} from 'zksync-web3';
import { Deployer } from '@matterlabs/hardhat-zksync-deploy';

import * as path from 'path';
import * as fs from 'fs';

import { Language, SYSTEM_CONTRACTS } from './constants';
import { formatUnits, parseUnits } from 'ethers/lib/utils';
import { BigNumber, ethers } from 'ethers';
import {readYulBytecode, publishFactoryDeps, DeployedDependency, Dependency, filterDeployedFactoryDeps,} from './utils';

const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));

// Maximum length of the combined length of dependencies
const MAX_COMBINED_LENGTH = 90000;

class ZkSyncDeployer {
    deployer: Deployer;
    gasPrice: BigNumber;
    nonce: number;
    deployedDependencies: DeployedDependency[];
    defaultAA?: DeployedDependency;
    bootloader?: DeployedDependency;
    constructor(deployer: Deployer, gasPrice: BigNumber, nonce: number) {
        this.deployer = deployer;
        this.gasPrice = gasPrice;
        this.nonce = nonce;
        this.deployedDependencies = [];
    }

    async publishFactoryDeps(
        dependencies: Dependency[],
    ): Promise<DeployedDependency[]> {
        let deployedDependencies = await publishFactoryDeps(
            dependencies,
            this.deployer,
            this.nonce,
            this.gasPrice
        );
        this.nonce += 1;

        return deployedDependencies;
    }

    async publishDefaultAA() {
        const [defaultAccountBytecodes, ] = await filterDeployedFactoryDeps('DefaultAccount', [(await this.deployer.loadArtifact('DefaultAccount')).bytecode], this.deployer);
        
        if (defaultAccountBytecodes.length == 0) {
            console.log('Default account bytecode is already published, skipping');
            return;
        }

        let deployedDependencies = await this.publishFactoryDeps(
            [{
                name: 'DefaultAccount',
                bytecodes: defaultAccountBytecodes,
            }],
        );
        this.nonce += 1;
        this.defaultAA = deployedDependencies[0];
    }

    async publishBootloader() {
        console.log('\nPublishing bootloader bytecode:');
        const bootloaderCode = ethers.utils.hexlify(fs.readFileSync('./bootloader/build/artifacts/proved_block.yul/proved_block.yul.zbin'));

        const [deps, ] = await filterDeployedFactoryDeps('Bootloader', [bootloaderCode], this.deployer);

        if (deps.length == 0) {
            console.log('Default bootloader bytecode is already published, skipping');
            return;
        }

        const deployedDependencies = await this.publishFactoryDeps(
            [{
                name: 'Bootloader',
                bytecodes: deps,
            }],
        );
        this.bootloader = deployedDependencies[0];
    }

    async prepareContractsForPublishing(): Promise<Dependency[]> {
        const dependenciesToDeploy: Dependency[] = [];
        for(const contract of Object.values(SYSTEM_CONTRACTS)) {
            let contractName = contract.codeName;
            let factoryDeps: string[] = [];
            if (contract.lang == Language.Solidity) {
                const artifact = await this.deployer.loadArtifact(contractName);
                factoryDeps = [
                    ...await this.deployer.extractFactoryDeps(artifact),
                    artifact.bytecode
                ];
            } else {
                // Yul files have only one dependency
                factoryDeps = [
                    readYulBytecode(contract)
                ];
            }

            let [bytecodesToDeploy, currentLength] = await filterDeployedFactoryDeps(contractName, factoryDeps, this.deployer);
            if (bytecodesToDeploy.length == 0) {
                console.log(`All bytecodes for ${contractName} are already published, skipping`);
                continue;
            }
            if(currentLength > MAX_COMBINED_LENGTH) {
                throw new Error(`Can not publish dependencies of contract ${contractName}`);
            }

            dependenciesToDeploy.push({
                name: contractName,
                bytecodes: bytecodesToDeploy,
                address: contract.address
            });
        }

        return dependenciesToDeploy;
    }

    async publishDependencies(dependenciesToDeploy: Dependency[]) {
        let currentLength = 0;
        let currentDependencies: Dependency[] = [];
        // We iterate over dependencies and try to batch the publishing of those in order to save up on gas as well as time.
        for (let dependency of dependenciesToDeploy) {
            const dependencyLength = dependency.bytecodes.reduce((prev, dep) => prev + ethers.utils.arrayify(dep).length, 0);
            if (currentLength + dependencyLength > MAX_COMBINED_LENGTH) {
                const deployedDependencies =  await this.publishFactoryDeps(
                    currentDependencies,
                );
                currentLength = dependencyLength;
                currentDependencies = [dependency];
                this.deployedDependencies.push(...deployedDependencies);
            } else {
                currentLength += dependencyLength;
                currentDependencies.push(dependency);
            }
        }
        if (currentDependencies.length > 0) {
            const deployedDependencies = await this.publishFactoryDeps(
                currentDependencies,
            );
            this.deployedDependencies.push(...deployedDependencies);    
        }
    }

    returnResult() {
        return {
            systemContracts: this.deployedDependencies,
            defaultAA: this.defaultAA,
            bootloader: this.bootloader,
        }
    }
}


export function l1RpcUrl() {
    return process.env.ETH_CLIENT_WEB3_URL as string;
}

export function l2RpcUrl() {
    return process.env.API_WEB3_JSON_RPC_HTTP_URL as string;
}

async function main() {
    const program = new Command();

    program.version('0.1.0').name('publish preimages').description('publish preimages for the L2 contracts');

    program
        .option('--private-key <private-key>')
        .option('--gas-price <gas-price>')
        .option('--nonce <nonce>')
        .option('--l1Rpc <l1Rpc>')
        .option('--l2Rpc <l2Rpc>')
        .option('--bootloader')
        .option('--default-aa')
        .option('--system-contracts')
        .option('--file <file>')
        .action(async (cmd) => {
            const l1Rpc = cmd.l1Rpc ? cmd.l1Rpc : l1RpcUrl();
            const l2Rpc = cmd.l2Rpc ? cmd.l2Rpc : l2RpcUrl();
            const providerL1 = new ethers.providers.JsonRpcProvider(l1Rpc);
            const providerL2 = new Provider(l2Rpc);
            const wallet= cmd.privateKey
            ? new Wallet(cmd.privateKey)
                : Wallet.fromMnemonic(
                    process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
                    "m/44'/60'/0'/0/1"
                );
            wallet.connect(providerL2);
            wallet.connectToL1(providerL1);

            const deployer = new Deployer(hre, wallet);
            deployer.zkWallet = deployer.zkWallet.connect(providerL2).connectToL1(providerL1);
            deployer.ethWallet = deployer.ethWallet.connect(providerL1);
            const ethWallet = deployer.ethWallet;

            console.log(`Using deployer wallet: ${ethWallet.address}`);

            const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, 'gwei') : await providerL1.getGasPrice();
            console.log(`Using gas price: ${formatUnits(gasPrice, 'gwei')} gwei`);

            let nonce = cmd.nonce ? parseInt(cmd.nonce) : await ethWallet.getTransactionCount();
            console.log(`Using nonce: ${nonce}`);

            const zkSyncDeployer = new ZkSyncDeployer(deployer, gasPrice, nonce);
            if (cmd.bootloader) {
                await zkSyncDeployer.publishBootloader();
            }

            if (cmd.defaultAa) {
                await zkSyncDeployer.publishDefaultAA();
            }

            if (cmd.systemContracts) {
                const dependencies = await zkSyncDeployer.prepareContractsForPublishing();
                await zkSyncDeployer.publishDependencies(dependencies);
            }

            const result = zkSyncDeployer.returnResult();
            console.log(JSON.stringify(result));
            if (cmd.file) {
                fs.writeFileSync(cmd.file, JSON.stringify(result));
            }
            console.log('\nPublishing factory dependencies complete!');

        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
