import { Command } from 'commander';
import { Wallet, ethers } from 'ethers';
import * as fs from 'fs';
import { Deployer } from '../../ethereum/src.ts/deploy';
import * as path from 'path';
import { getNumberFromEnv, web3Provider } from '../../ethereum/scripts/utils';
import * as hre from 'hardhat';
import { REQUIRED_L2_GAS_PRICE_PER_PUBDATA } from './utils';

const PRIORITY_TX_MAX_GAS_LIMIT = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');
const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));

function getContractBytecode(contractName: string) {
    return hre.artifacts.readArtifactSync(contractName).bytecode;
}

async function main() {
    const program = new Command();

    program.version('0.1.0').name('publish-bridge-preimages');

    program
        .option('--private-key <private-key>')
        .option('--nonce <nonce>')
        .option('--gas-price <gas-price>')
        .action(async (cmd) => {
            const wallet = cmd.privateKey
                ? new Wallet(cmd.privateKey, provider)
                : Wallet.fromMnemonic(
                      process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
                      "m/44'/60'/0'/0/1"
                  ).connect(provider);
            console.log(`Using wallet: ${wallet.address}`);

            const nonce = cmd.nonce ? parseInt(cmd.nonce) : await wallet.getTransactionCount();
            console.log(`Using nonce: ${nonce}`);

            const gasPrice = cmd.gasPrice ? parseInt(cmd.gasPrice) : await wallet.getGasPrice();
            console.log(`Using gas price: ${gasPrice}`);

            const deployer = new Deployer({ deployWallet: wallet });
            const zkSync = deployer.zkSyncContract(wallet);

            const publishL2ERC20BridgeTx = await zkSync.requestL2Transaction(
                ethers.constants.AddressZero,
                0,
                '0x',
                PRIORITY_TX_MAX_GAS_LIMIT,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                [getContractBytecode('L2ERC20Bridge')],
                wallet.address,
                { nonce, gasPrice }
            );
            await publishL2ERC20BridgeTx.wait();
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
