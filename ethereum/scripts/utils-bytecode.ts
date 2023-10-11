import { ethers } from 'ethers';
import * as chalk from 'chalk';
import * as fs from 'fs';
import * as path from 'path';

const warning = chalk.bold.yellow;
const CREATE2_PREFIX = ethers.utils.solidityKeccak256(['string'], ['zksyncCreate2']);
export const L1_TO_L2_ALIAS_OFFSET = '0x1111000000000000000000000000000000001111';

export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require('../../SystemConfig.json').REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

const contractArtifactsPath = path.join(process.env.ZKSYNC_HOME as string || "./", 'contracts/zksync/artifacts-zk/');
const l2BridgeArtifactsPath = path.join(contractArtifactsPath, 'cache-zk/solpp-generated-contracts/bridge/');
const openzeppelinTransparentProxyArtifactsPath = path.join(
    contractArtifactsPath,
    '@openzeppelin/contracts/proxy/transparent'
);
const openzeppelinBeaconProxyArtifactsPath = path.join(contractArtifactsPath, '@openzeppelin/contracts/proxy/beacon');

export const L2_ERC20_BRIDGE_PROXY_BYTECODE = readBytecode(
    openzeppelinTransparentProxyArtifactsPath,
    'TransparentUpgradeableProxy'
);
export const L2_WETH_BRIDGE_PROXY_BYTECODE = readBytecode(
    openzeppelinTransparentProxyArtifactsPath,
    'TransparentUpgradeableProxy'
);
export const L2_WETH_PROXY_BYTECODE = readBytecode(
    openzeppelinTransparentProxyArtifactsPath,
    'TransparentUpgradeableProxy'
);
export const L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, 'L2ERC20Bridge');
export const L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, 'L2StandardERC20');
export const L2_STANDARD_ERC20_PROXY_BYTECODE = readBytecode(openzeppelinBeaconProxyArtifactsPath, 'BeaconProxy');
export const L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE = readBytecode(
    openzeppelinBeaconProxyArtifactsPath,
    'UpgradeableBeacon'
);
export const L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, 'L2WethBridge');
export const L2_WETH_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, 'L2Weth');

export const L2_WETH_INTERFACE = readInterface(l2BridgeArtifactsPath, 'L2Weth');
export const L2_WETH_BRIDGE_INTERFACE = readInterface(l2BridgeArtifactsPath, 'L2WethBridge');
export const L2_ERC20_BRIDGE_INTERFACE = readInterface(l2BridgeArtifactsPath, 'L2ERC20Bridge');

export function readBatchBootloaderBytecode() {
    const bootloaderPath = path.join(process.env.ZKSYNC_HOME as string, `etc/system-contracts/bootloader`);
    return fs.readFileSync(`${bootloaderPath}/build/artifacts/proved_batch.yul/proved_batch.yul.zbin`);
}

export function readSystemContractsBytecode(fileName: string) {
    const systemContractsPath = path.join(process.env.ZKSYNC_HOME as string, `etc/system-contracts`);
    const artifact = fs.readFileSync(
        `${systemContractsPath}/artifacts-zk/cache-zk/solpp-generated-contracts/${fileName}.sol/${fileName}.json`
    );
    return JSON.parse(artifact.toString()).bytecode;
}

export function readBytecode(path: string, fileName: string) {
    return JSON.parse(fs.readFileSync(`${path}/${fileName}.sol/${fileName}.json`, { encoding: 'utf-8' })).bytecode;
}

export function readInterface(path: string, fileName: string) {
    const abi = JSON.parse(fs.readFileSync(`${path}/${fileName}.sol/${fileName}.json`, { encoding: 'utf-8' })).abi;
    return new ethers.utils.Interface(abi);
}