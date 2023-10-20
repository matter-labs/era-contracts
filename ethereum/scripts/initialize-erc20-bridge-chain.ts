import { Command } from 'commander';
import { ethers, Wallet } from 'ethers';
import { Deployer } from '../src.ts/deploy';
import { formatUnits, parseUnits } from 'ethers/lib/utils';
import { web3Provider, getNumberFromEnv, REQUIRED_L2_GAS_PRICE_PER_PUBDATA } from './utils';
import {
    L2_ERC20_BRIDGE_PROXY_BYTECODE,
    L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE,
    L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE,
    L2_STANDARD_ERC20_PROXY_BYTECODE,
    L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE
} from './utils-bytecode';

import * as fs from 'fs';
import * as path from 'path';

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));

const DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = getNumberFromEnv('CONTRACTS_DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT');

async function main() {
    const program = new Command();

    program.version('0.1.0').name('initialize-bridges-chain');

    program
        .option('--private-key <private-key>')
        .option('--chain-id <chain-id>')
        .option('--gas-price <gas-price>')
        .option('--nonce <nonce>')
        .option('--erc20-bridge <erc20-bridge>')
        .action(async (cmd) => {
            const chainId: string = cmd.chainId ? cmd.chainId : process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID;
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
                ownerAddress: deployWallet.address,
                verbose: true
            });

            const bridgehead = deployer.bridgehubContract(deployWallet);
            const erc20Bridge = cmd.erc20Bridge
                ? deployer.defaultERC20Bridge(deployWallet).attach(cmd.erc20Bridge)
                : deployer.defaultERC20Bridge(deployWallet);

            const priorityTxMaxGasLimit = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');

            // There will be two deployments done during the initial initialization
            const requiredValueToInitializeBridge = await bridgehead.l2TransactionBaseCost(
                chainId,
                gasPrice,
                DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA
            );

            const requiredValueToPublishBytecodes = await bridgehead.l2TransactionBaseCost(
                chainId,
                gasPrice,
                priorityTxMaxGasLimit,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA
            );

            const independentInitialization = [
                bridgehead.requestL2Transaction(
                    chainId,
                    ethers.constants.AddressZero,
                    0,
                    '0x',
                    priorityTxMaxGasLimit,
                    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                    [L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE, L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE],
                    deployWallet.address,
                    { gasPrice, nonce, value: requiredValueToPublishBytecodes }
                ),
                erc20Bridge.initializeChain(
                    chainId,
                    [
                        L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE,
                        L2_ERC20_BRIDGE_PROXY_BYTECODE,
                        L2_STANDARD_ERC20_PROXY_BYTECODE
                    ],
                    requiredValueToInitializeBridge,
                    requiredValueToInitializeBridge,
                    {
                        gasPrice,
                        nonce: nonce + 1,
                        value: requiredValueToInitializeBridge.mul(2)
                    }
                )
            ];

            const txs = await Promise.all(independentInitialization);
            for (const tx of txs) {
                console.log(`Transaction sent with hash ${tx.hash} and nonce ${tx.nonce}. Waiting for receipt...`);
            }
            const receipts = await Promise.all(txs.map((tx) => tx.wait(2)));

            console.log(`ERC20 bridge priority tx sent to hyperchain, gasUsed: ${receipts[1].gasUsed.toString()}`);
            console.log(`CONTRACTS_L2_ERC20_BRIDGE_ADDR=${await erc20Bridge.l2Bridge()}`);
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
