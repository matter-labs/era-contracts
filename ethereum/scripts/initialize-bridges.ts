import { Command } from 'commander';
import { ethers, Wallet } from 'ethers';
import { Deployer } from '../src.ts/deploy';
import { formatUnits, parseUnits } from 'ethers/lib/utils';
import { computeL2Create2Address, web3Provider, hashL2Bytecode, applyL1ToL2Alias } from './utils';
import {
    L2_ERC20_BRIDGE_PROXY_BYTECODE,
    L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE,
    L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE,
    L2_STANDARD_ERC20_PROXY_BYTECODE,
    L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE,
    L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE,
    L2_WETH_BRIDGE_PROXY_BYTECODE,
    L2_WETH_IMPLEMENTATION_BYTECODE,
    L2_WETH_PROXY_BYTECODE,
    L2_WETH_BRIDGE_INTERFACE,
    L2_ERC20_BRIDGE_INTERFACE,
    L2_WETH_INTERFACE
} from './utils-bytecode';
import { IBridgehubFactory } from '../typechain/IBridgehubFactory';

import * as fs from 'fs';
import * as path from 'path';

const provider = web3Provider();
const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, `etc/test_config/constant`);
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));

async function initializeBridges(
    deployer: Deployer,
    deployWallet: Wallet,
    gasPrice: ethers.BigNumber,
    cmdErc20Bridge: string
) {
    const bridgehub = IBridgehubFactory.connect(process.env.CONTRACTS_BRIDGEHEAD_DIAMOND_PROXY_ADDR, deployWallet);
    const nonce = await deployWallet.getTransactionCount();

    const erc20Bridge = cmdErc20Bridge
        ? deployer.defaultERC20Bridge(deployWallet).attach(cmdErc20Bridge)
        : deployer.defaultERC20Bridge(deployWallet);

    console.log('KL todo', bridgehub.address);
    const l1GovernorAddress = await bridgehub.getGovernor();
    // Check whether governor is a smart contract on L1 to apply alias if needed.
    const l1GovernorCodeSize = ethers.utils.hexDataLength(await deployWallet.provider.getCode(l1GovernorAddress));
    const l2GovernorAddress = l1GovernorCodeSize == 0 ? l1GovernorAddress : applyL1ToL2Alias(l1GovernorAddress);
    const abiCoder = new ethers.utils.AbiCoder();

    const l2ERC20BridgeImplAddr = computeL2Create2Address(
        applyL1ToL2Alias(erc20Bridge.address),
        L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE,
        '0x',
        ethers.constants.HashZero
    );

    const proxyInitializationParams = L2_ERC20_BRIDGE_INTERFACE.encodeFunctionData('initialize', [
        erc20Bridge.address,
        hashL2Bytecode(L2_STANDARD_ERC20_PROXY_BYTECODE),
        l2GovernorAddress
    ]);
    const l2ERC20BridgeProxyAddr = computeL2Create2Address(
        applyL1ToL2Alias(erc20Bridge.address),
        L2_ERC20_BRIDGE_PROXY_BYTECODE,
        ethers.utils.arrayify(
            abiCoder.encode(
                ['address', 'address', 'bytes'],
                [l2ERC20BridgeImplAddr, l2GovernorAddress, proxyInitializationParams]
            )
        ),
        ethers.constants.HashZero
    );

    const l2StandardToken = computeL2Create2Address(
        l2ERC20BridgeProxyAddr,
        L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE,
        '0x',
        ethers.constants.HashZero
    );
    const l2TokenFactoryAddr = computeL2Create2Address(
        l2ERC20BridgeProxyAddr,
        L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE,
        ethers.utils.arrayify(abiCoder.encode(['address'], [l2StandardToken])),
        ethers.constants.HashZero
    );

    const independentInitialization = [
        erc20Bridge.initialize(
            [L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE, L2_ERC20_BRIDGE_PROXY_BYTECODE, L2_STANDARD_ERC20_PROXY_BYTECODE],
            l2TokenFactoryAddr,
            l2GovernorAddress,
            {
                gasPrice,
                nonce: nonce
            }
        )
    ];

    const txs = await Promise.all(independentInitialization);
    for (const tx of txs) {
        console.log(`Transaction sent with hash ${tx.hash} and nonce ${tx.nonce}. Waiting for receipt...`);
    }
    const receipts = await Promise.all(txs.map((tx) => tx.wait(2)));

    console.log(`ERC20 bridge initialized on L1, gasUsed: ${receipts[0].gasUsed.toString()}`);
}
async function initializeWethBridges(deployer: Deployer, deployWallet: Wallet, gasPrice: ethers.BigNumber) {
    const bridgehub = deployer.bridgehubContract(deployWallet);
    const l1WethBridge = deployer.defaultWethBridge(deployWallet);
    const chainId = deployer.chainId;

    const abiCoder = new ethers.utils.AbiCoder();

    const l1GovernorAddress = await bridgehub.getGovernor();
    // Check whether governor is a smart contract on L1 to apply alias if needed.
    const l1GovernorCodeSize = ethers.utils.hexDataLength(await deployWallet.provider.getCode(l1GovernorAddress));
    const l2GovernorAddress = l1GovernorCodeSize == 0 ? l1GovernorAddress : applyL1ToL2Alias(l1GovernorAddress);

    const l2WethBridgeImplAddress = computeL2Create2Address(
        applyL1ToL2Alias(l1WethBridge.address),
        L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE,
        '0x',
        ethers.constants.HashZero
    );

    const l1WethAddress = await l1WethBridge.l1WethAddress();
    const bridgeProxyInitializationParams = L2_WETH_BRIDGE_INTERFACE.encodeFunctionData('initialize', [
        l1WethBridge.address,
        l1WethAddress,
        l2GovernorAddress
    ]);
    const l2WethBridgeProxyAddress = computeL2Create2Address(
        applyL1ToL2Alias(l1WethBridge.address),
        L2_WETH_BRIDGE_PROXY_BYTECODE,
        ethers.utils.arrayify(
            abiCoder.encode(
                ['address', 'address', 'bytes'],
                [l2WethBridgeImplAddress, l2GovernorAddress, bridgeProxyInitializationParams]
            )
        ),
        ethers.constants.HashZero
    );

    const l2WethImplAddress = computeL2Create2Address(
        l2WethBridgeProxyAddress,
        L2_WETH_IMPLEMENTATION_BYTECODE,
        '0x',
        ethers.constants.HashZero
    );

    const proxyInitializationParams = L2_WETH_INTERFACE.encodeFunctionData('initialize', ['Wrapped Ether', 'WETH']);
    const l2WethProxyAddress = computeL2Create2Address(
        l2WethBridgeProxyAddress,
        L2_WETH_PROXY_BYTECODE,
        ethers.utils.arrayify(
            abiCoder.encode(
                ['address', 'address', 'bytes'],
                [l2WethImplAddress, l2GovernorAddress, proxyInitializationParams]
            )
        ),
        ethers.constants.HashZero
    );

    const tx = await l1WethBridge.initialize(
        [L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE, L2_WETH_BRIDGE_PROXY_BYTECODE],
        l2WethProxyAddress,
        l2GovernorAddress,
        {
            gasPrice
        }
    );

    console.log(`Transaction sent with hash ${tx.hash} and nonce ${tx.nonce}. Waiting for receipt...`);

    const receipt = await tx.wait();

    console.log(`WETH bridge initialized, gasUsed: ${receipt.gasUsed.toString()}, ${chainId}`);
    console.log(`CONTRACTS_L2_WETH_BRIDGE_ADDR=${await l1WethBridge.l2Bridge(chainId)}`);
}

async function main() {
    const program = new Command();

    program.version('0.1.0').name('initialize-bridges-chain');

    program
        .option('--private-key <private-key>')
        .option('--chain-id <chain-id>')
        .option('--gas-price <gas-price>')
        .option('--nonce <nonce>')
        .option('--erc20-bridge <erc20-bridge>')
        .action(async (cmd) => {
            const chainId: string = cmd.chainId ? cmd.chainId : process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID;
            const deployWallet = cmd.privateKey
                ? new Wallet(cmd.privateKey, provider)
                : Wallet.fromMnemonic(
                      process.env.MNEMONIC ? process.env.MNEMONIC : ethTestConfig.mnemonic,
                      "m/44'/60'/0'/0/0"
                  ).connect(provider);
            console.log(`Using deployer wallet: ${deployWallet.address}`);

            const gasPrice = cmd.gasPrice ? parseUnits(cmd.gasPrice, 'gwei') : await provider.getGasPrice();
            console.log(`Using gas price: ${formatUnits(gasPrice, 'gwei')} gwei`);

            const nonce = cmd.nonce ? parseInt(cmd.nonce) : await deployWallet.getTransactionCount();
            console.log(`Using nonce: ${nonce}`);

            const deployer = new Deployer({
                deployWallet,
                verbose: true
            });
            deployer.chainId = parseInt(chainId) || 270;
            await initializeBridges(deployer, deployWallet, gasPrice, cmd.erc20Bridge);
            await initializeWethBridges(deployer, deployWallet, gasPrice);
        });

    await program.parseAsync(process.argv);
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('Error:', err);
        process.exit(1);
    });
