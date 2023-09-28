import * as hardhat from 'hardhat';
import { Interface } from 'ethers/lib/utils';
import { Command } from 'commander';
import { PermissionToCall, AccessMode, print, getLowerCaseAddress, permissionToCallComparator } from './utils';

// Get the interfaces for all needed contracts
const allowList = new Interface(hardhat.artifacts.readArtifactSync('IAllowList').abi);
const zkSync = new Interface(hardhat.artifacts.readArtifactSync('IZkSync').abi);
const l1ERC20Bridge = new Interface(hardhat.artifacts.readArtifactSync('L1ERC20Bridge').abi);

const ZKSYNC_MAINNET_ADDRESS = '0x32400084c286cf3e17e7b677ea9583e60a000324';
const L1_ERC20_BRIDGE_MAINNET_ADDRESS = '0x57891966931Eb4Bb6FB81430E6cE0A03AAbDe063';

const ALPHA_MAINNET_ALLOW_LIST = [
    {
        target: ZKSYNC_MAINNET_ADDRESS,
        functionName: 'requestL2Transaction'
    },
    {
        target: L1_ERC20_BRIDGE_MAINNET_ADDRESS,
        functionName: 'deposit'
    },
    {
        target: L1_ERC20_BRIDGE_MAINNET_ADDRESS,
        functionName: 'claimFailedDeposit'
    },
    {
        target: L1_ERC20_BRIDGE_MAINNET_ADDRESS,
        functionName: 'finalizeWithdrawal'
    }
];

function functionSelector(functionName: string): string {
    let selectors = new Array(0);

    try {
        selectors.push(zkSync.getSighash(zkSync.getFunction(functionName)));
    } catch {}

    try {
        selectors.push(l1ERC20Bridge.getSighash(l1ERC20Bridge.getFunction(functionName)));
    } catch {}

    if (selectors.length == 0) {
        throw `No selector found for the ${functionName} function`;
    }

    if (selectors.length > 1) {
        throw `More than one selectors found for the ${functionName} function`;
    }

    return selectors[0];
}

function setBatchPermissionToCall(parameters: Array<PermissionToCall>) {
    parameters.sort(permissionToCallComparator);
    for (let i = 1; i < parameters.length; i++) {
        if (permissionToCallComparator(parameters[i - 1], parameters[i]) === 0) {
            throw new Error('Duplicates for the set batch permission to call method');
        }
    }
    // Extend parameters with the function selector, to check it manually
    const extendedParameters = parameters.map((param) =>
        Object.assign(param, { functionSel: functionSelector(param.functionName) })
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
}

function setPermissionToCall(caller: string, target: string, functionName: string, enable: boolean) {
    const functionSel = functionSelector(functionName);
    print('parameters', { caller, target, functionName, functionSel, enable });

    const calldata = allowList.encodeFunctionData('setPermissionToCall', [caller, target, functionSel, enable]);
    print('setPermissionToCall', calldata);
}

function setAccessMode(target: string, mode: number) {
    print('parameters', { target, mode });

    const calldata = allowList.encodeFunctionData('setAccessMode', [target, mode]);
    print('setAccessMode', calldata);
}

function setBatchAccessMode(parameters: Array<AccessMode>) {
    parameters.sort((a, b) => getLowerCaseAddress(a.target).localeCompare(getLowerCaseAddress(b.target)));
    for (let i = 1; i < parameters.length; i++) {
        if (getLowerCaseAddress(parameters[i - 1].target) === getLowerCaseAddress(parameters[i].target)) {
            throw new Error('Duplicated targets for the set batch access mode method');
        }
    }
    print('parameters', parameters);

    const targets = parameters.map((publicAccess) => publicAccess.target);
    const modes = parameters.map((publicAccess) => publicAccess.mode);

    const calldata = allowList.encodeFunctionData('setBatchAccessMode', [targets, modes]);
    print('setBatchAccessMode', calldata);
}

async function main() {
    const program = new Command();

    program.version('0.1.0').name('allow-list-manager');

    const prepareCalldataProgram = program.command('prepare-calldata');

    prepareCalldataProgram
        .command('set-permission-to-call')
        .requiredOption('--caller <caller-address>')
        .requiredOption('--target <target-address>')
        .requiredOption('--function-name <function-name>')
        .requiredOption('--enable <enable>')
        .action((cmd) => {
            setPermissionToCall(cmd.caller, cmd.target, cmd.functionName, cmd.enable);
        });

    prepareCalldataProgram
        .command('set-batch-permission-to-call <permission-to-call>')
        .action((permissionToCall: string) => {
            const parameters: Array<PermissionToCall> = JSON.parse(permissionToCall);
            setBatchPermissionToCall(parameters);
        });

    prepareCalldataProgram
        .command('set-access-mode')
        .requiredOption('--target <target-address>')
        .requiredOption('--mode <mode>')
        .action((cmd) => {
            setAccessMode(cmd.target, cmd.mode);
        });

    prepareCalldataProgram.command('set-batch-access-mode <public-access>').action((publicAccess: string) => {
        const parameters = JSON.parse(publicAccess);
        setBatchAccessMode(parameters);
    });

    const alphaMainnet = program.command('alpha-mainnet');

    alphaMainnet.command('add <addresses>').action(async (addresses: string) => {
        const parsedAddresses = JSON.parse(addresses);
        let parameters: Array<PermissionToCall> = new Array(0);
        for (const caller of parsedAddresses) {
            for (const permission of ALPHA_MAINNET_ALLOW_LIST) {
                parameters.push({ caller, enable: true, ...permission });
            }
        }

        setBatchPermissionToCall(parameters);
    });

    alphaMainnet.command('remove <addresses>').action(async (addresses: string) => {
        const parsedAddresses = JSON.parse(addresses);
        let parameters: Array<PermissionToCall> = new Array(0);
        for (const caller of parsedAddresses) {
            for (const permission of ALPHA_MAINNET_ALLOW_LIST) {
                parameters.push({ caller, enable: false, ...permission });
            }
        }

        setBatchPermissionToCall(parameters);
    });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
