import { Command } from 'commander';
import { Wallet } from 'ethers';
import { Deployer } from '../src.ts/deploy';
import * as fs from 'fs';
import * as path from 'path';
import { web3Provider } from './utils';

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));

export enum AccessMode {
    Closed = 0,
    SpecialAccessOnly = 1,
    Public = 2
}

async function main() {
    const program = new Command();

    program.version('0.1.0').name('initialize-l1-allow-list');

    program
        .option('--private-key <private-key>')
        .option('--nonce <nonce>')
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

            const deployer = new Deployer({ deployWallet: wallet });

            const allowListContract = deployer.l1AllowList(wallet);
            const tx = await allowListContract.setBatchAccessMode(
                [
                    deployer.addresses.ZkSync.DiamondProxy,
                    deployer.addresses.Bridges.ERC20BridgeProxy,
                    deployer.addresses.Bridges.WethBridgeProxy
                ],
                [AccessMode.Public, AccessMode.Public, AccessMode.Public],
                { nonce }
            );
            await tx.wait();
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
