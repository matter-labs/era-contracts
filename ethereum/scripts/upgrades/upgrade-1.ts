import * as hardhat from 'hardhat';
import { Command } from 'commander';
import { deployedAddressesFromEnv } from '../src.ts/deploy';
import { getNumberFromEnv } from './utils';
import { diamondCut } from '../src.ts/diamondCut';
import { BigNumberish, BytesLike } from 'ethers';
import { ethers } from 'hardhat';

type DeploymentPram = {
    bytecodeHash: string;
    newAddress: string;
    value: BigNumberish;
    input: string;
};

const priorityTxMaxGasLimit = getNumberFromEnv('CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT');
const ZERO_ADDRESS = ethers.constants.AddressZero;

async function main() {
    const program = new Command();

    program.version('0.1.0').name('upgrade-l2-force-deploy');

    program
        .command('prepare-upgrade-params <deployment-params>')
        .option('--factory-deps <factory-deps>')
        .action(async (deploymentParams: string, cmd) => {
            // Get deployed L1 contract addresses from environment variables and interfaces for them
            const l1Contracts = deployedAddressesFromEnv();

            const diamondUpgradeInit = await hardhat.ethers.getContractAt('DiamondUpgradeInit', ZERO_ADDRESS);
            const diamondCutFacet = await hardhat.ethers.getContractAt('DiamondCutFacet', ZERO_ADDRESS);
            const l2Deployer = await hardhat.ethers.getContractAt('IContractDeployer', ZERO_ADDRESS);

            // Encode data for the upgrade call
            const params: Array<DeploymentPram> = JSON.parse(deploymentParams);
            const encodedParams = await l2Deployer.interface.encodeFunctionData('forceDeployOnAddresses', [params]);
            const factoryDeps: Array<BytesLike> = cmd.factoryDeps ? JSON.parse(cmd.factoryDeps) : [];

            // Prepare the diamond cut data
            const upgradeInitData = await diamondUpgradeInit.interface.encodeFunctionData('forceDeployL2Contract', [
                encodedParams,
                factoryDeps,
                priorityTxMaxGasLimit
            ]);
            const upgradeParam = diamondCut([], l1Contracts.ZkSync.DiamondUpgradeInit, upgradeInitData);

            // Get transaction data of the `proposeDiamondCut`
            const proposeDiamondCut = await diamondCutFacet.interface.encodeFunctionData('proposeDiamondCut', [
                upgradeParam.facetCuts,
                upgradeParam.initAddress
            ]);

            // Get transaction data of the `executeDiamondCutProposal`
            const executeDiamondCutProposal = await diamondCutFacet.interface.encodeFunctionData(
                'executeDiamondCutProposal',
                [upgradeParam]
            );

            console.log(`proposeDiamondCut\n${proposeDiamondCut}\n`);
            console.log(`executeDiamondCutProposal\n${executeDiamondCutProposal}\n`);
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
