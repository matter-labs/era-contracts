import { Command } from 'commander';
import { diamondCut } from '../../src.ts/diamondCut';
import { BigNumberish } from 'ethers';
import { ethers } from 'hardhat';
import { Provider, Wallet } from 'zksync-web3';
import '@nomiclabs/hardhat-ethers';
import { web3Provider } from '../utils';
import { Deployer } from '../../src.ts/deploy';
import * as fs from 'fs';
import * as path from 'path';
import { applyL1ToL2Alias, hashBytecode } from 'zksync-web3/build/src/utils';

type ForceDeployment = {
    bytecodeHash: string;
    newAddress: string;
    callConstructor: boolean;
    value: BigNumberish;
    input: string;
};

function sleep(millis: number) {
    return new Promise((resolve) => setTimeout(resolve, millis));
}

async function prepareCalldata(
    diamondUpgradeAddress: string,
    l2WethTokenDeployment: ForceDeployment,
    otherDeployments: Array<ForceDeployment>
) {
    const diamondUpgradeInit6 = await ethers.getContractAt('DiamondUpgradeInit6', ZERO_ADDRESS);
    const newDeployerSystemContract = await ethers.getContractAt('IL2ContractDeployer', ZERO_ADDRESS);

    const upgradeL2WethTokenCalldata = await newDeployerSystemContract.interface.encodeFunctionData(
        'forceDeployOnAddresses',
        [[l2WethTokenDeployment]]
    );

    const upgradeSystemContractsCalldata = await newDeployerSystemContract.interface.encodeFunctionData(
        'forceDeployOnAddresses',
        [otherDeployments]
    );

    // Prepare the diamond cut data
    const upgradeInitData = await diamondUpgradeInit6.interface.encodeFunctionData('forceDeploy', [
        upgradeL2WethTokenCalldata,
        upgradeSystemContractsCalldata,
        [] // Empty factory deps
    ]);

    return diamondCut([], diamondUpgradeAddress, upgradeInitData);
}

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));
const zksProvider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);

const ZERO_ADDRESS = ethers.constants.AddressZero;

async function getCalldata(
    diamondUpgradeAddress: string,
    params: ForceDeployment[],
    l2WethTokenProxyAddress: string,
    l2WethTokenImplAddress: string
) {
    // Generate wallet with random private key to load main contract governor.
    const randomWallet = new Wallet(ethers.utils.randomBytes(32), zksProvider, provider);
    let governor = await (await randomWallet.getMainContract()).getGovernor();
    // Apply L1 to L2 mask if needed.
    if (ethers.utils.hexDataLength(await provider.getCode(governor)) != 0) {
        governor = applyL1ToL2Alias(governor);
    }

    // This is TransparentUpgradeable proxy
    const constructorInput = ethers.utils.defaultAbiCoder.encode(
        ['address', 'address', 'bytes'],
        [l2WethTokenImplAddress, governor, '0x']
    );
    const bytecodeHash = ethers.utils.hexlify(hashBytecode(await zksProvider.getCode(l2WethTokenProxyAddress)));

    const l2WethUpgrade: ForceDeployment = {
        newAddress: l2WethTokenProxyAddress,
        bytecodeHash,
        callConstructor: true,
        value: 0,
        input: constructorInput
    };
    // Get diamond cut data
    return await prepareCalldata(diamondUpgradeAddress, l2WethUpgrade, params);
}

async function main() {
    const program = new Command();

    program.version('0.1.0').name('force-deploy-upgrade-6');

    program
        .command('prepare-calldata')
        .requiredOption('--diamond-upgrade-address <diamond-upgrade-address>')
        .requiredOption('--deployment-params <deployment-params>')
        .requiredOption('--l2WethTokenProxyAddress <l2-weth-token-proxy-address>')
        .requiredOption('--l2WethTokenImplAddress <l2-weth-token-impl-address>')
        .action(async (cmd) => {
            // Get address of the diamond init contract
            const diamondUpgradeAddress = cmd.diamondUpgradeAddress;
            // Get L2 WETH token proxy address
            const l2WethTokenProxyAddress = cmd.l2WethTokenProxyAddress;
            // Get L2 WETH token implementation address
            const l2WethTokenImplAddress = cmd.l2WethTokenImplAddress;
            // Encode data for the upgrade call
            const params: Array<ForceDeployment> = JSON.parse(cmd.deploymentParams);

            // Get diamond cut data
            const calldata = await getCalldata(
                diamondUpgradeAddress,
                params,
                l2WethTokenProxyAddress,
                l2WethTokenImplAddress
            );
            console.log(calldata);
        });

    program
        .command('force-upgrade')
        .option('--private-key <private-key>')
        .option('--proposal-id <proposal-id>')
        .requiredOption('--diamond-upgrade-address <diamond-upgrade-address>')
        .requiredOption('--deployment-params <deployment-params>')
        .requiredOption('--l2WethTokenProxyAddress <l2-weth-token-proxy-address>')
        .requiredOption('--l2WethTokenImplAddress <l2-weth-token-impl-address>')
        .action(async (cmd) => {
            const deployWallet = cmd.privateKey
                ? new ethers.Wallet(cmd.privateKey, provider)
                : ethers.Wallet.fromMnemonic(
                      process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
                      "m/44'/60'/0'/0/1"
                  ).connect(provider);

            const deployer = new Deployer({
                deployWallet,
                governorAddress: ZERO_ADDRESS,
                verbose: true
            });
            const zkSyncContract = deployer.zkSyncContract(deployWallet);

            // Get address of the diamond init contract
            const diamondUpgradeAddress = cmd.diamondUpgradeAddress;
            // Encode data for the upgrade call
            const params: Array<ForceDeployment> = JSON.parse(cmd.deploymentParams);
            // Get L2 WETH token proxy address
            const l2WethTokenProxyAddress = cmd.l2WethTokenProxyAddress;
            // Get L2 WETH token implementation address
            const l2WethTokenImplAddress = cmd.l2WethTokenImplAddress;

            // Get diamond cut data
            const upgradeParam = await getCalldata(
                diamondUpgradeAddress,
                params,
                l2WethTokenProxyAddress,
                l2WethTokenImplAddress
            );

            const proposalId = cmd.proposalId ? cmd.proposalId : (await zkSyncContract.getCurrentProposalId()).add(1);
            const proposeUpgradeTx = await zkSyncContract.proposeTransparentUpgrade(upgradeParam, proposalId);
            await proposeUpgradeTx.wait();

            const executeUpgradeTx = await zkSyncContract.executeUpgrade(upgradeParam, ethers.constants.HashZero);
            const executeUpgradeRec = await executeUpgradeTx.wait();
            const deployL2TxHashes = executeUpgradeRec.events
                .filter((event) => event.event === 'NewPriorityRequest')
                .map((event) => event.args[1]);
            for (const txHash of deployL2TxHashes) {
                console.log(txHash);
                let receipt = null;
                while (receipt == null) {
                    receipt = await zksProvider.getTransactionReceipt(txHash);
                    await sleep(100);
                }

                if (receipt.status != 1) {
                    throw new Error('Failed to process L2 tx');
                }
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
