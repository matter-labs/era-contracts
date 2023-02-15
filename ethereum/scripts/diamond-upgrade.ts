import * as hardhat from 'hardhat';
import { Command } from 'commander';
import { diamondCut } from '../src.ts/diamondCut';
import { ethers } from 'hardhat';
import { Deployer } from '../src.ts/deploy';
import { print, web3Provider } from './utils';
import { FacetCut, getAllSelectors } from '../src.ts/diamondCut';

const provider = web3Provider();
const ZERO_ADDRESS = ethers.constants.AddressZero;

function getZkSyncContract() {
    // Create the dummy wallet with provider to get contracts from `Deployer`
    const dummyWallet = ethers.Wallet.createRandom().connect(provider);
    const deployer = new Deployer({ deployWallet: dummyWallet });

    return deployer.zkSyncContract(dummyWallet);
}

async function main() {
    const program = new Command();

    program.version('0.1.0').name('upgrade-diamond');

    program.command('get-contract-selectors <contract-name>').action(async (contractName: string) => {
        const contract = await hardhat.ethers.getContractAt(contractName, ZERO_ADDRESS);
        const selectors = getAllSelectors(contract.interface);

        print('Contract selectors', selectors);
    });

    program.command('diamond-loupe-view').action(async () => {
        const facets = await getZkSyncContract().facets();

        print('Facets', facets);
    });

    program
        .command('legacy-prepare-upgrade-calldata <facetCuts>')
        .option('--init-address <init-address>')
        .option('--init-data <init-data>')
        .action(async (facetCutsData: string, cmd) => {
            const diamondCutFacet = await hardhat.ethers.getContractAt('IOldDiamondCut', ZERO_ADDRESS);

            // Encode data for the upgrade call
            const facetCuts: Array<FacetCut> = JSON.parse(facetCutsData);

            const initAddress = cmd.initAddress ? cmd.initAddress : ZERO_ADDRESS;
            const initData = cmd.initData ? cmd.initData : '0x';

            const upgradeParam = diamondCut(facetCuts, initAddress, initData);
            print('DiamondCutData', upgradeParam);

            // Get transaction data of the `proposeDiamondCut`
            const proposeUpgrade = await diamondCutFacet.interface.encodeFunctionData('proposeDiamondCut', [
                upgradeParam.facetCuts,
                upgradeParam.initAddress
            ]);

            // Get transaction data of the `executeDiamondCutProposal`
            const executeUpgrade = await diamondCutFacet.interface.encodeFunctionData('executeDiamondCutProposal', [
                upgradeParam
            ]);

            print('proposeUpgrade', proposeUpgrade);
            print('executeUpgrade', executeUpgrade);
        });

    program
        .command('prepare-upgrade-calldata <facetCuts>')
        .option('--init-address <init-address>')
        .option('--init-data <init-data>')
        .option('--proposal-id <proposal-id>')
        .action(async (facetCutsData: string, cmd) => {
            const diamondCutFacet = await hardhat.ethers.getContractAt('DiamondCutFacet', ZERO_ADDRESS);

            // Encode data for the upgrade call
            const facetCuts: Array<FacetCut> = JSON.parse(facetCutsData);

            const initAddress = cmd.initAddress ? cmd.initAddress : ZERO_ADDRESS;
            const initData = cmd.initData ? cmd.initData : '0x';
            const proposalId = cmd.proposalId
                ? cmd.proposalId
                : (await getZkSyncContract().getCurrentProposalId()).add(1);

            const upgradeParam = diamondCut(facetCuts, initAddress, initData);
            print('DiamondCut', upgradeParam);

            // Get transaction data of the `proposeTransparentUpgrade`
            const proposeUpgrade = await diamondCutFacet.interface.encodeFunctionData('proposeTransparentUpgrade', [
                upgradeParam,
                proposalId
            ]);

            // Get transaction data of the `executeDiamondCutProposal`
            const executeUpgrade = await diamondCutFacet.interface.encodeFunctionData('executeUpgrade', [
                upgradeParam,
                ethers.constants.HashZero
            ]);

            print('proposeUpgrade', proposeUpgrade);
            print('executeUpgrade', executeUpgrade);
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
