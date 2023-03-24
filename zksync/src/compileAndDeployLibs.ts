import { Command } from 'commander';
import { TASK_COMPILE } from 'hardhat/builtin-tasks/task-names';
import { ethers, Wallet } from 'ethers';
import { computeL2Create2Address, create2DeployFromL1, getNumberFromEnv } from './utils';
import { web3Provider } from '../../ethereum/scripts/utils';
import * as fs from 'fs';
import * as path from 'path';
import * as hre from 'hardhat';

const provider = web3Provider();
const priorityTxMaxGasLimit = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));

// At the moment, the zk-EVM Solidity compiler supports linking libraries only at compile time.
// So, in order to compile smart contracts, we need to know the address of all deployed libraries.
// Furthermore, contracts that we are trying to deploy are the main part of the bridges, so we cannot deploy them as usual from L2
// There are no bridges - there are no tokens to pay for the tx - transaction cannot be executed, the chicken or the egg situation.
//
// Therefore we do the following:
// 1. Compile the smart contracts.
// 2. Deploy compiled libraries them from L1. (then we don't care about the fees & L2 tokens)
// 3. Link the smart contracts with the deployed libraries.
// 4. Compile the smart contracts again.
async function main() {
    const program = new Command();

    program
        .version('0.1.0')
        .name('compile-and-deploy-libs')
        .description('Compile contracts & deploy libraries & recompile contracts');

    program
        .option('--no-deploy', 'Do not deploy the library')
        .option('--private-key <private-key>')
        .action(async (cmd: Command) => {
            const deployWallet = cmd.privateKey
                ? new Wallet(cmd.privateKey, provider)
                : Wallet.fromMnemonic(
                      process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
                      "m/44'/60'/0'/0/1"
                  ).connect(provider);
            console.log(`Using deployer wallet: ${deployWallet.address}`);

            // Compile contract to get bytecode of the library.
            await hre.run(TASK_COMPILE, { quiet: true });

            const libBytecode = hre.artifacts.readArtifactSync('ExternalDecoder').bytecode;
            const create2Salt = ethers.constants.HashZero;
            const externalDecoderLib = computeL2Create2Address(deployWallet, libBytecode, '0x', create2Salt);

            // Link smart contracts to the library.
            // @ts-ignore
            hre.config.zksolc.settings.libraries = {
                'cache-zk/solpp-generated-contracts/ExternalDecoder.sol': {
                    ExternalDecoder: externalDecoderLib
                }
            };

            // Compile already contracts that were linked.
            await hre.run(TASK_COMPILE, { force: true });

            if (cmd.deploy) {
                // TODO: request from API how many L2 gas is needed for the transaction.
                await create2DeployFromL1(deployWallet, libBytecode, '0x', create2Salt, priorityTxMaxGasLimit);
            }
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
