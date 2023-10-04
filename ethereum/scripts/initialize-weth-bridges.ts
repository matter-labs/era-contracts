import { Command } from 'commander';
import { ethers, Wallet } from 'ethers';
import { Deployer } from '../src.ts/deploy';
import { formatUnits, parseUnits } from 'ethers/lib/utils';
import { web3Provider, applyL1ToL2Alias, getNumberFromEnv, REQUIRED_L2_GAS_PRICE_PER_PUBDATA } from './utils';

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

const L2_WETH_BRIDGE_PROXY_BYTECODE = readBytecode(
    openzeppelinTransparentProxyArtifactsPath,
    'TransparentUpgradeableProxy'
);
const L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, 'L2WethBridge');
const DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = getNumberFromEnv('CONTRACTS_DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT');

async function main() {
    const program = new Command();

    program.version('0.1.0').name('initialize-weth-bridges');

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
            console.log(`Using deployer nonce: ${nonce}`);

            const l2WethAddress = process.env.CONTRACTS_L2_WETH_TOKEN_PROXY_ADDR;

            const deployer = new Deployer({
                deployWallet,
                verbose: true
            });

            const zkSync = deployer.zkSyncContract(deployWallet);
            const l1WethBridge = deployer.defaultWethBridge(deployWallet);

            const l1GovernorAddress = await zkSync.getGovernor();
            // Check whether governor is a smart contract on L1 to apply alias if needed.
            const l1GovernorCodeSize = ethers.utils.hexDataLength(
                await deployWallet.provider.getCode(l1GovernorAddress)
            );
            const l2GovernorAddress = l1GovernorCodeSize == 0 ? l1GovernorAddress : applyL1ToL2Alias(l1GovernorAddress);

            // There will be two deployments done during the initial initialization
            const requiredValueToInitializeBridge = await zkSync.l2TransactionBaseCost(
                gasPrice,
                DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA
            );

            const tx = await l1WethBridge.initialize(
                [L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE, L2_WETH_BRIDGE_PROXY_BYTECODE],
                l2WethAddress,
                l2GovernorAddress,
                requiredValueToInitializeBridge,
                requiredValueToInitializeBridge,
                {
                    gasPrice,
                    value: requiredValueToInitializeBridge.mul(2)
                }
            );
            console.log(`Transaction sent with hash ${tx.hash} and nonce ${tx.nonce}. Waiting for receipt...`);

            const receipt = await tx.wait();

            console.log(`WETH bridge initialized, gasUsed: ${receipt.gasUsed.toString()}`);
            console.log(`CONTRACTS_L2_WETH_BRIDGE_ADDR=${await l1WethBridge.l2Bridge()}`);
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
