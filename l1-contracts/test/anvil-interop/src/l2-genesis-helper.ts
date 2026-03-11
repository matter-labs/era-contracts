import * as fs from "fs";
import * as path from "path";
import { utils } from "ethers";
import { ETH_TOKEN_ADDRESS, L1_CHAIN_ID, ZK_CHAIN_SPECIFIC_FORCE_DEPLOYMENTS_DATA_TUPLE_TYPE } from "./const";
import { applyL1ToL2Alias } from "./utils";
import { encodeNtvAssetId } from "./data-encoding";

/**
 * Helper for building L2GenesisUpgrade data structures
 *
 * CRITICAL: The L2 contracts (L2MessageRoot, L2NativeTokenVault, L2AssetRouter, etc.)
 * MUST be compiled using REGULAR SOLC (NOT zksolc). They are stored in out/ directory.
 *
 * These contracts are compiled with regular Solc and deployed via L2GenesisUpgrade during
 * chain initialization. The Solc bytecode is then padded and hashed for L2 deployment.
 *
 * Solc bytecode characteristics:
 * - May NOT be divisible by 32 (we pad with zeros)
 * - After padding, length in words may be even (we add another 32 bytes if needed)
 * - Hash uses SHA256 (not keccak256) to match ZKsync L2 format
 * - Hash format: version (1) | marker (0x00) | length_in_words (2 bytes) | sha256[28 bytes]
 *
 * DO NOT use zksolc or zkout/ - these contracts MUST come from regular Solc compilation.
 */

interface BytecodeInfo {
  messageRootBytecodeHash: string;
  l2NtvBytecodeHash: string;
  l2AssetRouterBytecodeHash: string;
  bridgehubBytecodeHash: string;
  chainAssetHandlerBytecodeHash: string;
}

interface FixedForceDeploymentsData {
  l1ChainId: bigint;
  eraChainId: bigint;
  l1AssetRouter: string;
  l2TokenProxyBytecodeHash: string;
  aliasedL1Governance: string;
  maxNumberOfZKChains: bigint;
  bridgehubBytecodeHash: string;
  l2AssetRouterBytecodeHash: string;
  l2NtvBytecodeHash: string;
  messageRootBytecodeHash: string;
  chainAssetHandlerBytecodeHash: string;
  l2SharedBridgeLegacyImpl: string;
  l2BridgedStandardERC20Impl: string;
  dangerousTestOnlyForcedBeacon: string;
}

interface ZKChainSpecificForceDeploymentsData {
  l2LegacySharedBridge: string;
  predeployedL2WethAddress: string;
  baseTokenL1Address: string;
  baseTokenMetadata: {
    name: string;
    symbol: string;
    decimals: number;
  };
  baseTokenBridgingData: {
    assetId: string;
    originChainId: bigint;
    originToken: string;
  };
}

/**
 * Compute ZKsync L2 bytecode hash for SOLC-compiled contracts
 *
 * IMPORTANT: Input bytecode MUST be from regular Solc (NOT zksolc).
 * This function pads the Solc bytecode to meet ZKsync L2 requirements:
 * 1. Pad to be divisible by 32 bytes
 * 2. Ensure odd word count (add 32 bytes if word count is even)
 * 3. Hash with SHA256 (not keccak256)
 *
 * Hash format (32 bytes):
 * [0x01] [0x00] [length_high_byte] [length_low_byte] [sha256_last_28_bytes]
 *
 * DO NOT use this with zksolc bytecode - only regular Solc bytecode.
 */
function hashL2Bytecode(bytecode: string): string {
  // Remove 0x prefix if present
  if (bytecode.startsWith("0x")) {
    bytecode = bytecode.slice(2);
  }

  const bytecodeBytes = Buffer.from(bytecode, "hex");
  let length = bytecodeBytes.length;

  // Step 1: Pad Solc bytecode to be divisible by 32
  if (length % 32 !== 0) {
    const paddingNeeded = 32 - (length % 32);
    const padding = "0".repeat(paddingNeeded * 2); // 2 hex chars per byte
    bytecode = bytecode + padding;
    length = length + paddingNeeded;
  }

  let lengthInWords = length / 32;

  // Step 2: Ensure odd word count (ZKsync L2 requirement)
  // Solc bytecode often has even word count, so we add 32 bytes (1 word) of padding
  if (lengthInWords % 2 === 0) {
    bytecode = bytecode + "0".repeat(64); // Add 32 bytes (64 hex chars)
    length = length + 32;
    lengthInWords = length / 32;
  }

  // Compute SHA256 hash (not keccak256!) of the padded bytecode
  const hash = utils.sha256("0x" + bytecode);

  // Build the bytecode hash per L2ContractHelper.sol:
  // hashedBytecode = utils.sha256(_bytecode) & 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
  // hashedBytecode = (hashedBytecode | bytes32(uint256(1 << 248)))  // Set version = 1
  // hashedBytecode = hashedBytecode | bytes32(bytecodeLenInWords << 224)  // Set length

  const hashBytes = hash.slice(2); // Remove 0x
  const hashLast28Bytes = hashBytes.slice(8); // Keep last 28 bytes (skip first 4 bytes = 8 hex chars)

  const version = "01";
  const marker = "00";
  const lengthBytes = lengthInWords.toString(16).padStart(4, "0");

  return "0x" + version + marker + lengthBytes + hashLast28Bytes;
}

/**
 * Read SOLC-compiled bytecode from out/ artifacts
 *
 * CRITICAL: These L2 contracts MUST be compiled with REGULAR SOLC (NOT zksolc).
 * They are deployed during L2 genesis upgrade via the L2ComplexUpgrader.
 *
 * The bytecode from Solc will be padded by hashL2Bytecode() to meet ZKsync requirements:
 * - Padded to be divisible by 32
 * - Padded to have odd word count
 *
 * DO NOT read from zkout/ - must read from out/ (regular Solc compilation).
 */
function readSolcBytecode(contractsRoot: string, fileName: string, contractName: string): string {
  const artifactPath = path.join(contractsRoot, "l1-contracts/out", fileName, `${contractName}.json`);

  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Solc artifact not found: ${artifactPath}. Make sure to compile with 'forge build' (NOT --zksync)`);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf-8"));
  let bytecode = artifact.bytecode?.object || artifact.bytecode;

  if (!bytecode) {
    throw new Error(`No bytecode found in artifact: ${artifactPath}`);
  }

  // Ensure it has 0x prefix
  if (!bytecode.startsWith("0x")) {
    bytecode = "0x" + bytecode;
  }

  return bytecode;
}

/**
 * Build bytecode info by reading SOLC-compiled bytecode and computing ZKsync L2 bytecode hashes
 *
 * CRITICAL: These L2 contracts MUST be compiled with REGULAR SOLC (NOT zksolc).
 *
 * Process:
 * 1. Read Solc-compiled bytecode from l1-contracts/out/
 * 2. Pad bytecode to be divisible by 32 bytes
 * 3. Pad bytecode to have odd word count (ZKsync requirement)
 * 4. Compute ZKsync L2 bytecode hash (version + length + SHA256)
 * 5. Encode as bytes32 for use in L2GenesisUpgrade
 *
 * DO NOT use zksolc or zkout/ - these contracts MUST come from regular Solc.
 * Run 'forge build' (WITHOUT --zksync flag) to generate out/ artifacts.
 */
export function getBytecodeInfo(contractsRoot: string): BytecodeInfo {
  const info: BytecodeInfo = {
    messageRootBytecodeHash: "",
    l2NtvBytecodeHash: "",
    l2AssetRouterBytecodeHash: "",
    bridgehubBytecodeHash: "",
    chainAssetHandlerBytecodeHash: "",
  };

  const contracts = [
    { file: "L2MessageRoot.sol", name: "L2MessageRoot", key: "messageRootBytecodeHash" as const },
    { file: "L2NativeTokenVault.sol", name: "L2NativeTokenVault", key: "l2NtvBytecodeHash" as const },
    { file: "L2AssetRouter.sol", name: "L2AssetRouter", key: "l2AssetRouterBytecodeHash" as const },
    { file: "L2Bridgehub.sol", name: "L2Bridgehub", key: "bridgehubBytecodeHash" as const },
    { file: "L2ChainAssetHandler.sol", name: "L2ChainAssetHandler", key: "chainAssetHandlerBytecodeHash" as const },
  ];

  for (const contract of contracts) {
    const bytecode = readSolcBytecode(contractsRoot, contract.file, contract.name);
    info[contract.key] = hashL2Bytecode(bytecode); // V29 uses bytes32 directly, not ABI-encoded
  }

  return info;
}

/**
 * Build FixedForceDeploymentsData
 */
export function buildFixedForceDeploymentsData(
  chainId: number,
  l1AssetRouter: string,
  bytecodeInfo: BytecodeInfo,
  l1Governance: string,
  l1ChainId: number = L1_CHAIN_ID
): string {
  const data: FixedForceDeploymentsData = {
    l1ChainId: BigInt(l1ChainId),
    eraChainId: BigInt(chainId),
    l1AssetRouter: l1AssetRouter,
    l2TokenProxyBytecodeHash: "0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70",
    aliasedL1Governance: applyL1ToL2Alias(l1Governance),
    maxNumberOfZKChains: BigInt(100),
    bridgehubBytecodeHash: bytecodeInfo.bridgehubBytecodeHash,
    l2AssetRouterBytecodeHash: bytecodeInfo.l2AssetRouterBytecodeHash,
    l2NtvBytecodeHash: bytecodeInfo.l2NtvBytecodeHash,
    messageRootBytecodeHash: bytecodeInfo.messageRootBytecodeHash,
    chainAssetHandlerBytecodeHash: bytecodeInfo.chainAssetHandlerBytecodeHash,
    l2SharedBridgeLegacyImpl: "0x0000000000000000000000000000000000000000",
    l2BridgedStandardERC20Impl: "0x0000000000000000000000000000000000000000",
    dangerousTestOnlyForcedBeacon: "0x0000000000000000000000000000000000000000",
  };

  const abiCoder = new utils.AbiCoder();
  return abiCoder.encode(
    [
      "tuple(uint256 l1ChainId, uint256 eraChainId, address l1AssetRouter, bytes32 l2TokenProxyBytecodeHash, address aliasedL1Governance, uint256 maxNumberOfZKChains, bytes32 bridgehubBytecodeHash, bytes32 l2AssetRouterBytecodeHash, bytes32 l2NtvBytecodeHash, bytes32 messageRootBytecodeHash, bytes32 chainAssetHandlerBytecodeHash, address l2SharedBridgeLegacyImpl, address l2BridgedStandardERC20Impl, address dangerousTestOnlyForcedBeacon)",
    ],
    [
      [
        data.l1ChainId,
        data.eraChainId,
        data.l1AssetRouter,
        data.l2TokenProxyBytecodeHash,
        data.aliasedL1Governance,
        data.maxNumberOfZKChains,
        data.bridgehubBytecodeHash,
        data.l2AssetRouterBytecodeHash,
        data.l2NtvBytecodeHash,
        data.messageRootBytecodeHash,
        data.chainAssetHandlerBytecodeHash,
        data.l2SharedBridgeLegacyImpl,
        data.l2BridgedStandardERC20Impl,
        data.dangerousTestOnlyForcedBeacon,
      ],
    ]
  );
}

/**
 * Build ZKChainSpecificForceDeploymentsData
 */
export function buildAdditionalForceDeploymentsData(baseTokenL1Address: string): string {
  const abiCoder = new utils.AbiCoder();
  const baseTokenAssetId = encodeNtvAssetId(L1_CHAIN_ID, baseTokenL1Address);

  const data: ZKChainSpecificForceDeploymentsData = {
    l2LegacySharedBridge: "0x0000000000000000000000000000000000000000",
    predeployedL2WethAddress: ETH_TOKEN_ADDRESS,
    baseTokenL1Address: baseTokenL1Address,
    baseTokenMetadata: {
      name: "Ether",
      symbol: "ETH",
      decimals: 18,
    },
    baseTokenBridgingData: {
      assetId: baseTokenAssetId,
      originChainId: BigInt(L1_CHAIN_ID),
      originToken: baseTokenL1Address,
    },
  };

  return abiCoder.encode(
    [ZK_CHAIN_SPECIFIC_FORCE_DEPLOYMENTS_DATA_TUPLE_TYPE],
    [
      [
        data.l2LegacySharedBridge,
        data.predeployedL2WethAddress,
        data.baseTokenL1Address,
        [data.baseTokenMetadata.name, data.baseTokenMetadata.symbol, data.baseTokenMetadata.decimals],
        [
          data.baseTokenBridgingData.assetId,
          data.baseTokenBridgingData.originChainId,
          data.baseTokenBridgingData.originToken,
        ],
      ],
    ]
  );
}
