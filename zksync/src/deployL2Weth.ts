import { Command } from 'commander';
import { ethers, Wallet } from 'ethers';
import { Deployer } from '../../ethereum/src.ts/deploy';
import { formatUnits, parseUnits } from 'ethers/lib/utils';
import { web3Provider } from '../../ethereum/scripts/utils';

import { getNumberFromEnv, create2DeployFromL1, computeL2Create2Address } from './utils';

import * as fs from 'fs';
import * as path from 'path';

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));

const contractArtifactsPath = path.join(process.env.ZKSYNC_HOME as string, 'contracts/zksync/artifacts-zk/');
const l2BridgeArtifactsPath = path.join(contractArtifactsPath, 'cache-zk/solpp-generated-contracts/bridge/');

const openzeppelinTransparentProxyArtifactsPath = path.join(
    contractArtifactsPath,
    '@openzeppelin/contracts/proxy/transparent/'
);

function readBytecode(path: string, fileName: string) {
    return JSON.parse(fs.readFileSync(`${path}/${fileName}.sol/${fileName}.json`, { encoding: 'utf-8' })).bytecode;
}

function readInterface(path: string, fileName: string) {
    const abi = JSON.parse(fs.readFileSync(`${path}/${fileName}.sol/${fileName}.json`, { encoding: 'utf-8' })).abi;
    return new ethers.utils.Interface(abi);
}

const L2_WETH_INTERFACE = readInterface(l2BridgeArtifactsPath, 'L2WETH');

const L2_WETH_PROXY_BYTECODE = readBytecode(openzeppelinTransparentProxyArtifactsPath, 'TransparentUpgradeableProxy');

const L2_WETH_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, 'L2WETH');

async function main() {
    const program = new Command();

    program.version('0.1.0').name('initialize-bridges');

    program
        .option('--private-key <private-key>')
        .option('--gas-price <gas-price>')
        .option('--nonce <nonce>')
        .action(async (cmd) => {
            const deployWallet = cmd.privateKey
                ? new Wallet(cmd.privateKey, provider)
                : Wallet.fromMnemonic(
                      process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
                      "m/44'/60'/0'/0/0"
                  ).connect(provider);
            console.log(`Using deployer wallet: ${deployWallet.address}`);

            const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, 'gwei') : await provider.getGasPrice();
            console.log(`Using gas price: ${formatUnits(gasPrice, 'gwei')} gwei`);

            const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
            console.log(`Using nonce: ${nonce}`);

            const deployer = new Deployer({
                deployWallet,
                governorAddress: deployWallet.address,
                verbose: true
            });

            const zkSync = deployer.zkSyncContract(deployWallet);

            const priorityTxMaxGasLimit = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');
            const governorAddress = await zkSync.getGovernor();
            const abiCoder = new ethers.utils.AbiCoder();

            const l2WethImplAddr = computeL2Create2Address(
                deployWallet,
                L2_WETH_IMPLEMENTATION_BYTECODE,
                '0x',
                ethers.constants.HashZero
            );

            const proxyInitializationParams = L2_WETH_INTERFACE.encodeFunctionData('initialize', [
                'Wrapped Ether',
                'WETH'
            ]);
            const l2ERC20BridgeProxyConstructor = ethers.utils.arrayify(
                abiCoder.encode(
                    ['address', 'address', 'bytes'],
                    [l2WethImplAddr, governorAddress, proxyInitializationParams]
                )
            );
            const l2ERC20BridgeProxyAddr = computeL2Create2Address(
                deployWallet,
                L2_WETH_PROXY_BYTECODE,
                l2ERC20BridgeProxyConstructor,
                ethers.constants.HashZero
            );

            await create2DeployFromL1(
                deployWallet,
                L2_WETH_IMPLEMENTATION_BYTECODE,
                '0x',
                ethers.constants.HashZero,
                priorityTxMaxGasLimit
            );

            await create2DeployFromL1(
                deployWallet,
                L2_WETH_PROXY_BYTECODE,
                l2ERC20BridgeProxyConstructor,
                ethers.constants.HashZero,
                priorityTxMaxGasLimit
            );

            console.log(`CONTRACTS_L2_WETH_IMPLEMENTATION_ADDR=${l2WethImplAddr}`);
            console.log(`CONTRACTS_L2_WETH_PROXY_ADDR=${l2ERC20BridgeProxyAddr}`);
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
