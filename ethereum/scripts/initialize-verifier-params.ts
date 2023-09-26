import { Command } from 'commander';
import { Wallet } from 'ethers';
import { Deployer } from '../src.ts/deploy';
import { formatUnits, parseUnits } from 'ethers/lib/utils';
import { web3Provider, getHashFromEnv } from './utils';

import * as fs from 'fs';
import * as path from 'path';

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));

async function main() {
    const program = new Command();

    program
        .option('--private-key <private-key>')
        .option('--chain-id <chain-id>')
        .option('--gas-price <gas-price>')
        .option('--nonce <nonce>')
        .action(async (cmd) => {
            const deployWallet = cmd.privateKey
                ? new Wallet(cmd.privateKey, provider)
                : Wallet.fromMnemonic(
                      process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
                      "m/44'/60'/0'/0/1"
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

            const zkSync = deployer.proofSystemContract(deployWallet);
            const verifierParams = {
                recursionNodeLevelVkHash: getHashFromEnv('CONTRACTS_RECURSION_NODE_LEVEL_VK_HASH'),
                recursionLeafLevelVkHash: getHashFromEnv('CONTRACTS_RECURSION_LEAF_LEVEL_VK_HASH'),
                recursionCircuitsSetVksHash: getHashFromEnv('CONTRACTS_RECURSION_CIRCUITS_SET_VKS_HASH')
            };
            const initialDiamondCut = await deployer.initialProofSystemProxyDiamondCut();

            const tx = await zkSync.setParams(verifierParams, initialDiamondCut);
            console.log(`Transaction sent with hash ${tx.hash} and nonce ${tx.nonce}`);
            const receipt = await tx.wait();

            console.log(`Verifier Params are set, gasUsed: ${receipt.gasUsed.toString()}`);
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
