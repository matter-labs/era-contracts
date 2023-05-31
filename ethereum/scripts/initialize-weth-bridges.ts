import { Command } from 'commander';
import { ethers, Wallet } from 'ethers';
import { Deployer } from '../src.ts/deploy';
import { formatUnits, parseUnits } from 'ethers/lib/utils';
import {
    computeL2Create2Address,
    web3Provider,
    applyL1ToL2Alias,
    getNumberFromEnv,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
} from './utils';

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

const L2_WETH_BRIDGE_PROXY_BYTECODE = readBytecode(
    openzeppelinTransparentProxyArtifactsPath,
    'TransparentUpgradeableProxy'
);
const L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, 'L2WethBridge');
const L2_WETH_PROXY_BYTECODE = readBytecode(openzeppelinTransparentProxyArtifactsPath, 'TransparentUpgradeableProxy');
const L2_WETH_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, 'L2Weth');

const L2_WETH_BRIDGE_INTERFACE = readInterface(l2BridgeArtifactsPath, 'L2WethBridge');
const L2_WETH_INTERFACE = readInterface(l2BridgeArtifactsPath, 'L2Weth');

const DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = getNumberFromEnv('CONTRACTS_DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT');

async function main() {
    const program = new Command();

    program.version('0.1.0').name('initialize-weth-bridges');

    program
        .option('--deployer-private-key <deployer-private-key>')
        .requiredOption('--initializer-private-key <initializer-private-key>')
        .option('--gas-price <gas-price>')
        .option('--l1-weth-address <l1-weth-address>')
        .option('--nonce <nonce>')
        .action(async (cmd) => {
            const deployWallet = cmd.deployerPrivateKey
                ? new Wallet(cmd.deployerPrivateKey, provider)
                : Wallet.fromMnemonic(
                      process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
                      "m/44'/60'/0'/0/0"
                  ).connect(provider);
            console.log(`Using deployer wallet: ${deployWallet.address}`);

            const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, 'gwei') : await provider.getGasPrice();
            console.log(`Using gas price: ${formatUnits(gasPrice, 'gwei')} gwei`);

            const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
            console.log(`Using deployer nonce: ${nonce}`);

            const l1WethAddress = cmd.l1WethAddress || process.env.CONTRACTS_L1_WETH_TOKEN_ADDR;

            const deployer = new Deployer({
                deployWallet,
                governorAddress: deployWallet.address,
                verbose: true
            });

            const zkSync = deployer.zkSyncContract(deployWallet);

            const initializerWallet = new Wallet(cmd.initializerPrivateKey, provider);
            console.log(`Using initializer wallet: ${initializerWallet.address}`);
            const initializerNonce = await initializerWallet.getTransactionCount();
            console.log(`Using initializer nonce: ${initializerNonce}`);
            const wethBridge = deployer.defaultWethBridge(initializerWallet);

            const priorityTxMaxGasLimit = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');
            const governorAddress = await zkSync.getGovernor();
            const abiCoder = new ethers.utils.AbiCoder();

            const l2WethBridgeImplAddr = computeL2Create2Address(
                applyL1ToL2Alias(wethBridge.address),
                L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE,
                '0x',
                ethers.constants.HashZero
            );

            const l2WethBridgeProxyAddr = computeL2Create2Address(
                applyL1ToL2Alias(wethBridge.address),
                L2_WETH_BRIDGE_PROXY_BYTECODE,
                ethers.utils.arrayify(
                    abiCoder.encode(
                        ['address', 'address', 'bytes'],
                        [l2WethBridgeImplAddr, governorAddress, l2WethBridgeProxyInitializationParams]
                    )
                ),
                ethers.constants.HashZero
            );

            const l2WethAddr = computeL2Create2Address(
                l2WethBridgeProxyAddr,
                L2_WETH_IMPLEMENTATION_BYTECODE,
                '0x',
                ethers.constants.HashZero
            );

            const l2WethBridgeProxyInitializationParams = L2_WETH_BRIDGE_INTERFACE.encodeFunctionData('initialize', [
                wethBridge.address,
                l1WethAddress,
                l2WethAddr
            ]);

            const l2WethProxyInitializationParams = L2_WETH_INTERFACE.encodeFunctionData('bridgeInitialize', [
                l2WethBridgeImplAddr,
                deployer.addresses.WethToken,
                'Wrapped Ether',
                'WETH'
            ]);
            const l2WethProxyAddr = computeL2Create2Address(
                l2WethBridgeProxyAddr,
                L2_WETH_PROXY_BYTECODE,
                ethers.utils.arrayify(
                    abiCoder.encode(
                        ['address', 'address', 'bytes'],
                        [l2WethAddr, governorAddress, l2WethProxyInitializationParams]
                    )
                ),
                ethers.constants.HashZero
            );

            // There will be two deployments done during the initial initialization
            const requiredValueToInitializeBridge = await zkSync.l2TransactionBaseCost(
                gasPrice,
                DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA
            );

            const requiredValueToPublishBytecodes = await zkSync.l2TransactionBaseCost(
                gasPrice,
                priorityTxMaxGasLimit,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA
            );

            const independentInitialization = [
                zkSync.requestL2Transaction(
                    ethers.constants.AddressZero,
                    0,
                    '0x',
                    priorityTxMaxGasLimit,
                    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                    [L2_WETH_PROXY_BYTECODE, L2_WETH_IMPLEMENTATION_BYTECODE],
                    deployWallet.address,
                    { gasPrice, nonce, value: requiredValueToPublishBytecodes }
                ),
                wethBridge.initialize(
                    [L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE, L2_WETH_BRIDGE_PROXY_BYTECODE],
                    l2WethProxyAddr,
                    governorAddress,
                    requiredValueToInitializeBridge,
                    requiredValueToInitializeBridge,
                    {
                        gasPrice,
                        nonce: initializerNonce,
                        value: requiredValueToInitializeBridge.mul(2)
                    }
                )
            ];

            const txs = await Promise.all(independentInitialization);
            const receipts = await Promise.all(txs.map((tx) => tx.wait()));

            console.log(`WETH bridge initialized, gasUsed: ${receipts[1].gasUsed.toString()}`);
            console.log(`CONTRACTS_L2_WETH_BRIDGE_ADDR=${await wethBridge.l2Bridge()}`);
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
