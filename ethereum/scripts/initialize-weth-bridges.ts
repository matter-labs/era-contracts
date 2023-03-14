import { Command } from 'commander';
import { ethers, Wallet } from 'ethers';
import { Deployer } from '../src.ts/deploy';
import { formatUnits, parseUnits } from 'ethers/lib/utils';
import {
    computeL2Create2Address,
    web3Provider,
    hashL2Bytecode,
    applyL1ToL2Alias,
    getNumberFromEnv,
    DEFAULT_L2_GAS_PRICE_PER_PUBDATA
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
const openzeppelinBeaconProxyArtifactsPath = path.join(contractArtifactsPath, '@openzeppelin/contracts/proxy/beacon');

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
const L2_WETH_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, 'L2WethToken');
const L2_WETH_PROXY_BYTECODE = readBytecode(openzeppelinBeaconProxyArtifactsPath, 'TransparentUpgradeableProxy');
// const L2_WETH_PROXY_FACTORY_BYTECODE = readBytecode(
//     openzeppelinBeaconProxyArtifactsPath,
//     'UpgradeableBeacon'
// );
const L2_WETH_BRIDGE_INTERFACE = readInterface(l2BridgeArtifactsPath, 'L2WethBridge');

async function main() {
    const program = new Command();

    program.version('0.1.0').name('initialize-weth-bridges');

    program
        .option('--private-key <private-key>')
        .option('--gas-price <gas-price>')
        .option('--l1-weth-address <l1-weth-address>')
        // TODO: delete this option, find l2EthAddress from CONFIG
        .option('--l2-eth-address <l2-eth-address>')
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

            const l1WethAddress = cmd.l1WethAddress;
            const l2EthAddress = cmd.l2EthAddress;

            const deployer = new Deployer({
                deployWallet,
                governorAddress: deployWallet.address,
                verbose: true
            });

            const zkSync = deployer.zkSyncContract(deployWallet);
            const wethBridge = deployer.defaultWethBridge(deployWallet);

            const priorityTxMaxGasLimit = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');
            const governorAddress = await zkSync.getGovernor();
            const abiCoder = new ethers.utils.AbiCoder();

            const l2WethBridgeImplAddr = computeL2Create2Address(
                applyL1ToL2Alias(wethBridge.address),
                L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE,
                '0x',
                ethers.constants.HashZero
            );

            const proxyInitializationParams = L2_WETH_BRIDGE_INTERFACE.encodeFunctionData('initialize', [
                wethBridge.address,
                l1WethAddress,
                l2EthAddress, // l2EthAddress is the address of the L2 ETH token, pick this from CONFIG
                governorAddress
            ]);
            const l2WethBridgeProxyAddr = computeL2Create2Address(
                applyL1ToL2Alias(wethBridge.address),
                L2_WETH_BRIDGE_PROXY_BYTECODE,
                ethers.utils.arrayify(
                    abiCoder.encode(
                        ['address', 'address', 'bytes'],
                        [l2WethBridgeImplAddr, governorAddress, proxyInitializationParams]
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
            const l2WethProxyAddr = computeL2Create2Address(
                l2WethBridgeProxyAddr,
                L2_WETH_PROXY_BYTECODE,
                ethers.utils.arrayify(abiCoder.encode(['address', 'address'], [l2WethAddr, governorAddress])),
                ethers.constants.HashZero
            );

            const independentInitialization = [
                zkSync.requestL2Transaction(
                    ethers.constants.AddressZero,
                    0,
                    '0x',
                    priorityTxMaxGasLimit,
                    DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
                    [L2_WETH_PROXY_BYTECODE, L2_WETH_IMPLEMENTATION_BYTECODE],
                    deployWallet.address,
                    { gasPrice, nonce }
                ),
                wethBridge.initialize(
                    [
                        L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE,
                        L2_WETH_BRIDGE_PROXY_BYTECODE
                    ],
                    l2WethProxyAddr,
                    governorAddress,
                    {
                        gasPrice,
                        nonce: nonce + 1
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
