import * as path from 'path';
import { readBytecode, readInterface } from './utils';
export const L1_TO_L2_ALIAS_OFFSET = '0x1111000000000000000000000000000000001111';

export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require('../../SystemConfig.json').REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

const contractArtifactsPath = path.join((process.env.ZKSYNC_HOME as string) || './', 'contracts/zksync/artifacts-zk/');
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
