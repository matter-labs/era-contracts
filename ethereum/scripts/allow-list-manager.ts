import { Command } from 'commander';
import { ethers } from 'hardhat';
import { Deployer } from '../src.ts/deploy';
import { web3Provider, print } from './utils';
import { hexlify } from 'ethers/lib/utils';

const provider = web3Provider();

interface RermissionToCall {
    caller: string;
    target: string;
    functionSig: string;
    enable: boolean;
}

interface PublicAccess {
    target: string;
    enable: boolean;
}

// Get interface for the L1 allow list smart contract
function getAllowListInterface() {
    // Create the dummy wallet with provider to get contracts from `Deployer`
    const dummyWallet = ethers.Wallet.createRandom().connect(provider);
    const deployer = new Deployer({ deployWallet: dummyWallet });

    return deployer.l1AllowList(dummyWallet).interface;
}

// Get the solidity 4 bytes function selector from the function signature
// https://solidity-by-example.org/function-selector/
function functionSelector(functionSignature: string) {
    return hexlify(ethers.utils.solidityKeccak256(['string'], [functionSignature])).slice(0, 10);
}

async function main() {
    const program = new Command();

    program.version('0.1.0').name('allow-list-manager');

    const prepareCalldataProgram = program.command('prepare-calldata');

    prepareCalldataProgram
        .command('set-batch-permission-to-call <permission-to-call>')
        .action(async (permissionToCall: string) => {
            const allowList = getAllowListInterface();

            const parameters: Array<RermissionToCall> = JSON.parse(permissionToCall);
            // Extend parameters with the function selector, to check it manually
            const extendedParameters = parameters.map((param) =>
                Object.assign(param, { functionSel: functionSelector(param.functionSig) })
            );
            print('parameters', extendedParameters);

            const callers = extendedParameters.map((permissionToCall) => permissionToCall.caller);
            const targets = extendedParameters.map((permissionToCall) => permissionToCall.target);
            const functionSelectors = extendedParameters.map((permissionToCall) => permissionToCall.functionSel);
            const enables = extendedParameters.map((permissionToCall) => permissionToCall.enable);

            const calldata = allowList.encodeFunctionData('setBatchPermissionToCall', [
                callers,
                targets,
                functionSelectors,
                enables
            ]);
            print('setBatchPermissionToCall', calldata);
        });

    prepareCalldataProgram
        .command('set-permission-to-call')
        .requiredOption('--caller <caller-address>')
        .requiredOption('--target <target-address>')
        .requiredOption('--function-sig <function-sig>')
        .requiredOption('--enable <enable>')
        .action(async (cmd) => {
            const allowList = getAllowListInterface();
            const caller = cmd.caller;
            const target = cmd.target;
            const functionSig = cmd.functionSig;
            const functionSel = functionSelector(functionSig);
            const enable = cmd.enable;

            print('parameters', { caller, target, functionSig, functionSel, enable });

            const calldata = allowList.encodeFunctionData('setPermissionToCall', [caller, target, functionSel, enable]);
            print('setPermissionToCall', calldata);
        });

    prepareCalldataProgram
        .command('set-public-access')
        .requiredOption('--target <target-address>')
        .requiredOption('--enable <enable>')
        .action(async (cmd) => {
            const allowList = getAllowListInterface();
            const target = cmd.target;
            const enable = cmd.enable;

            print('parameters', { target, enable });

            const calldata = allowList.encodeFunctionData('setPublicAccess', [target, enable]);
            print('setPublicAccess', calldata);
        });

    prepareCalldataProgram.command('set-batch-public-access <public-access>').action(async (publicAccess: string) => {
        const allowList = getAllowListInterface();

        const parameters: Array<PublicAccess> = JSON.parse(publicAccess);
        print('parameters', parameters);

        const targets = parameters.map((publicAccess) => publicAccess.target);
        const enables = parameters.map((publicAccess) => publicAccess.enable);

        const calldata = allowList.encodeFunctionData('setBatchPublicAccess', [targets, enables]);
        print('setBatchPublicAccess', calldata);
    });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
