import { Command } from 'commander';
import { getFacetCutsForUpgrade } from '../src.ts/diamondCut';
import { BigNumber, ethers } from 'ethers';
import * as fs from 'fs';
import { deployViaCreate2 } from '../src.ts/deploy-utils';
import { web3Url } from 'zk/build/utils';
import * as path from 'path';
import { insertGasPrice } from './utils';

const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));

async function deployFacetCut(
    wallet: ethers.Wallet,
    name: string,
    create2Address: string,
    ethTxOptions: {},
    create2Salt?: string
) {
    create2Salt = create2Salt ?? ethers.constants.HashZero;

    ethTxOptions['gasLimit'] = 10_000_000;
    const [address, txHash] = await deployViaCreate2(wallet, name, [], create2Salt, ethTxOptions, create2Address, true);

    console.log(`Deployed ${name} at ${address} with txHash ${txHash}`);
    return [address, txHash];
}

async function deployFacetCuts(
    l1Rpc: string,
    names: string[],
    create2Address: string,
    file?: string,
    privateKey?: string,
    nonce?: number,
    gasPrice?: BigNumber,
    create2Salt?: string
) {
    const provider = new ethers.providers.JsonRpcProvider(l1Rpc);
    const wallet = privateKey
        ? new ethers.Wallet(privateKey, provider)
        : ethers.Wallet.fromMnemonic(
              process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
              "m/44'/60'/0'/0/1"
          ).connect(provider);
    const deployedFacets = {};
    let ethTxOptions = {};
    if (!nonce) {
        ethTxOptions['nonce'] = await wallet.getTransactionCount();
    } else {
        ethTxOptions['nonce'] = nonce;
    }
    if (!gasPrice) {
        await insertGasPrice(provider, ethTxOptions);
    }
    for (let i = 0; i < names.length; i++) {
        const [address, txHash] = await deployFacetCut(wallet, names[i], create2Address, ethTxOptions, create2Salt);
        ethTxOptions['nonce'] += 1;
        deployedFacets[names[i]] = { address, txHash };
    }
    console.log(JSON.stringify(deployedFacets, null, 2));
    if (file) {
        fs.writeFileSync(file, JSON.stringify(deployedFacets, null, 2));
    }
    return deployedFacets;
}

async function getFacetCuts(
    l1Rpc: string,
    zkSyncAddress: string,
    diamondCutFacetAddress: string,
    gettersAddress: string,
    mailboxAddress: string,
    executorAddress: string,
    governanceAddress: string,
    file?: string
) {
    const provider = new ethers.providers.JsonRpcProvider(l1Rpc);
    // It's required to send read-only requests to the provider. So, we don't care about the privatekey.
    const wallet = ethers.Wallet.fromMnemonic(ethTestConfig.mnemonic, "m/44'/60'/0'/0/1").connect(provider);

    const facetCuts = await getFacetCutsForUpgrade(
        wallet,
        zkSyncAddress,
        diamondCutFacetAddress,
        gettersAddress,
        mailboxAddress,
        executorAddress,
        governanceAddress
    );
    console.log(JSON.stringify(facetCuts, null, 2));
    if (file) {
        fs.writeFileSync(file, JSON.stringify(facetCuts, null, 2));
    }
}

export const command = new Command('facets').description('Facets related commands');

command
    .command('generate-facet-cuts')
    .option('--l1Rpc <l1Rpc>')
    .option('--file <file>')
    .requiredOption('--zkSyncAddress <zkSyncAddress>')
    .option('--diamond-cut-facet-address <diamondCutFacetAddress>')
    .option('--getters-address <gettersAddress>')
    .option('--mailbox-address <mailboxAddress>')
    .option('--executor-address <executorAddress>')
    .option('--governance-address <governanceAddress>')
    .description('get facet cuts for upgrade')
    .action(async (cmd) => {
        const l1Rpc = cmd.l1Rpc ?? web3Url();
        await getFacetCuts(
            l1Rpc,
            cmd.zkSyncAddress,
            cmd.diamondCutFacetAddress,
            cmd.gettersAddress,
            cmd.mailboxAddress,
            cmd.executorAddress,
            cmd.governanceAddress,
            cmd.file
        );
    });

command
    .command('deploy')
    .option('--l1Rpc <l1Rpc>')
    .option('--privateKey <privateKey>')
    .option('--create2-address <create2Address>')
    .option('--file <file>')
    .option('--nonce <nonce>')
    .option('--gasPrice <gasPrice>')
    .option('--create2-salt <create2Salt>')
    .option('--executor')
    .option('--governance')
    .option('--diamondCut')
    .option('--getters')
    .option('--mailbox')
    .description('deploy facet cuts')
    .action(async (cmd) => {
        const l1Rpc = cmd.l1Rpc ?? web3Url();
        const facetsToDeploy = [];
        if (cmd.executor) {
            facetsToDeploy.push('ExecutorFacet');
        }
        if (cmd.governance) {
            facetsToDeploy.push('GovernanceFacet');
        }
        if (cmd.diamondCut) {
            facetsToDeploy.push('DiamondCutFacet');
        }
        if (cmd.getters) {
            facetsToDeploy.push('GettersFacet');
        }
        if (cmd.mailbox) {
            facetsToDeploy.push('MailboxFacet');
        }
        await deployFacetCuts(
            l1Rpc,
            facetsToDeploy,
            cmd.create2Address,
            cmd.file,
            cmd.privateKey,
            cmd.nonce,
            cmd.gasPrice,
            cmd.create2Salt
        );
    });
