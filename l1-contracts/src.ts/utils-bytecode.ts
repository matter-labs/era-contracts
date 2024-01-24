import { ethers } from "ethers";
import * as path from "path";
import type { L1ERC20Bridge } from "../typechain";
import { applyL1ToL2Alias, computeL2Create2Address, hashL2Bytecode, readBytecode, readInterface } from "./utils";

export const L1_TO_L2_ALIAS_OFFSET = "0x1111000000000000000000000000000000001111";

// eslint-disable-next-line @typescript-eslint/no-var-requires
export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require("../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

const repoRoot = path.join(__dirname, "../..");
const contractArtifactsPath = path.join(repoRoot, "l2-contracts/artifacts-zk/");
const l2BridgeArtifactsPath = path.join(contractArtifactsPath, "cache-zk/solpp-generated-contracts/bridge/");
const openzeppelinTransparentProxyArtifactsPath = path.join(
  contractArtifactsPath,
  "@openzeppelin/contracts/proxy/transparent"
);
const openzeppelinBeaconProxyArtifactsPath = path.join(contractArtifactsPath, "@openzeppelin/contracts/proxy/beacon");

export const L2_ERC20_BRIDGE_PROXY_BYTECODE = readBytecode(
  openzeppelinTransparentProxyArtifactsPath,
  "TransparentUpgradeableProxy"
);
export const L2_WETH_BRIDGE_PROXY_BYTECODE = readBytecode(
  openzeppelinTransparentProxyArtifactsPath,
  "TransparentUpgradeableProxy"
);
export const L2_WETH_PROXY_BYTECODE = readBytecode(
  openzeppelinTransparentProxyArtifactsPath,
  "TransparentUpgradeableProxy"
);
export const L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, "L2ERC20Bridge");
export const L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, "L2StandardERC20");
export const L2_STANDARD_ERC20_PROXY_BYTECODE = readBytecode(openzeppelinBeaconProxyArtifactsPath, "BeaconProxy");
export const L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE = readBytecode(
  openzeppelinBeaconProxyArtifactsPath,
  "UpgradeableBeacon"
);
export const L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, "L2WethBridge");
export const L2_WETH_IMPLEMENTATION_BYTECODE = readBytecode(l2BridgeArtifactsPath, "L2Weth");

export const L2_WETH_INTERFACE = readInterface(l2BridgeArtifactsPath, "L2Weth");
export const L2_WETH_BRIDGE_INTERFACE = readInterface(l2BridgeArtifactsPath, "L2WethBridge");
export const L2_ERC20_BRIDGE_INTERFACE = readInterface(l2BridgeArtifactsPath, "L2ERC20Bridge");

export function calculateWethAddresses(
  l2GovernorAddress: string,
  l1WethBridgeAddress: string,
  l1WethAddress: string,
  ethIsBaseToken: boolean
): { l2WethImplAddress: string; l2WethProxyAddress: string; l2WethBridgeProxyAddress: string } {
  const abiCoder = new ethers.utils.AbiCoder();

  const l2WethBridgeImplAddress = computeL2Create2Address(
    applyL1ToL2Alias(l1WethBridgeAddress),
    L2_WETH_BRIDGE_IMPLEMENTATION_BYTECODE,
    "0x",
    ethers.constants.HashZero
  );

  const bridgeProxyInitializationParams = L2_WETH_BRIDGE_INTERFACE.encodeFunctionData("initialize", [
    l1WethBridgeAddress,
    l1WethAddress,
    l2GovernorAddress,
    ethIsBaseToken,
  ]);

  const l2WethBridgeProxyAddress = computeL2Create2Address(
    applyL1ToL2Alias(l1WethBridgeAddress),
    L2_WETH_BRIDGE_PROXY_BYTECODE,
    ethers.utils.arrayify(
      abiCoder.encode(
        ["address", "address", "bytes"],
        [l2WethBridgeImplAddress, l2GovernorAddress, bridgeProxyInitializationParams]
      )
    ),
    ethers.constants.HashZero
  );

  const l2WethImplAddress = computeL2Create2Address(
    l2WethBridgeProxyAddress,
    L2_WETH_IMPLEMENTATION_BYTECODE,
    "0x",
    ethers.constants.HashZero
  );

  const proxyInitializationParams = L2_WETH_INTERFACE.encodeFunctionData("initialize", ["Wrapped Ether", "WETH"]);
  const l2WethProxyAddress = computeL2Create2Address(
    l2WethBridgeProxyAddress,
    L2_WETH_PROXY_BYTECODE,
    ethers.utils.arrayify(
      abiCoder.encode(
        ["address", "address", "bytes"],
        [l2WethImplAddress, l2GovernorAddress, proxyInitializationParams]
      )
    ),
    ethers.constants.HashZero
  );

  return { l2WethImplAddress, l2WethProxyAddress, l2WethBridgeProxyAddress };
}

export function calculateERC20Addresses(
  l2GovernorAddress: string,
  erc20Bridge: L1ERC20Bridge
): { l2TokenFactoryAddr: string; l2ERC20BridgeProxyAddr: string } {
  const abiCoder = new ethers.utils.AbiCoder();

  const l2ERC20BridgeImplAddr = computeL2Create2Address(
    applyL1ToL2Alias(erc20Bridge.address),
    L2_ERC20_BRIDGE_IMPLEMENTATION_BYTECODE,
    "0x",
    ethers.constants.HashZero
  );

  const proxyInitializationParams = L2_ERC20_BRIDGE_INTERFACE.encodeFunctionData("initialize", [
    erc20Bridge.address,
    hashL2Bytecode(L2_STANDARD_ERC20_PROXY_BYTECODE),
    l2GovernorAddress,
  ]);

  const l2ERC20BridgeProxyAddr = computeL2Create2Address(
    applyL1ToL2Alias(erc20Bridge.address),
    L2_ERC20_BRIDGE_PROXY_BYTECODE,
    ethers.utils.arrayify(
      abiCoder.encode(
        ["address", "address", "bytes"],
        [l2ERC20BridgeImplAddr, l2GovernorAddress, proxyInitializationParams]
      )
    ),
    ethers.constants.HashZero
  );

  const l2StandardToken = computeL2Create2Address(
    l2ERC20BridgeProxyAddr,
    L2_STANDARD_ERC20_IMPLEMENTATION_BYTECODE,
    "0x",
    ethers.constants.HashZero
  );

  const l2TokenFactoryAddr = computeL2Create2Address(
    l2ERC20BridgeProxyAddr,
    L2_STANDARD_ERC20_PROXY_FACTORY_BYTECODE,
    ethers.utils.arrayify(abiCoder.encode(["address"], [l2StandardToken])),
    ethers.constants.HashZero
  );
  return { l2TokenFactoryAddr, l2ERC20BridgeProxyAddr };
}
