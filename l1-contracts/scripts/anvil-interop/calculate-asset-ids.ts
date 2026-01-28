#!/usr/bin/env node

import { AbiCoder, keccak256 } from "ethers";

/**
 * Calculate asset ID for a token in NativeTokenVault
 * Asset ID = keccak256(abi.encode(originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress))
 */
function calculateAssetId(chainId: number, tokenAddress: string): string {
  const L2_NATIVE_TOKEN_VAULT_ADDR = "0x0000000000000000000000000000000000010004";
  const abiCoder = AbiCoder.defaultAbiCoder();
  return keccak256(abiCoder.encode(["uint256", "address", "address"], [chainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress]));
}

/**
 * Calculate ETH asset ID for a given chain
 * ETH token address is conventionally 0x0000...0001
 */
function calculateEthAssetId(chainId: number): string {
  return calculateAssetId(chainId, "0x0000000000000000000000000000000000000001");
}

// Main execution
if (require.main === module) {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    console.log("Usage:");
    console.log("  ts-node calculate-asset-ids.ts <chainId> <tokenAddress>");
    console.log("  ts-node calculate-asset-ids.ts eth <chainId>");
    console.log("");
    console.log("Examples:");
    console.log("  ts-node calculate-asset-ids.ts 10 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512");
    console.log("  ts-node calculate-asset-ids.ts eth 1");
    process.exit(0);
  }

  if (args[0] === "eth") {
    const chainId = parseInt(args[1]);
    const assetId = calculateEthAssetId(chainId);
    console.log(`ETH Asset ID for chain ${chainId}:`);
    console.log(assetId);
  } else {
    const chainId = parseInt(args[0]);
    const tokenAddress = args[1];
    const assetId = calculateAssetId(chainId, tokenAddress);
    console.log(`Asset ID for token ${tokenAddress} on chain ${chainId}:`);
    console.log(assetId);
  }
}

export { calculateAssetId, calculateEthAssetId };
