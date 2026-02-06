#!/usr/bin/env node

import { JsonRpcProvider, Contract, Wallet } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { getDefaultAccountPrivateKey } from "./src/utils";

/**
 * Deploy MockL2MessageVerification on all L2 chains for Anvil testing
 * This deploys a contract that always returns true for message inclusion proofs
 */
async function main() {
  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l2) {
    throw new Error("No L2 chains found. Run 'yarn step1' first.");
  }

  console.log("\n=== Deploying MockL2MessageVerification (Anvil Testing) ===\n");

  const L2_MESSAGE_VERIFICATION_ADDR = "0x0000000000000000000000000000000000010009";
  const privateKey = getDefaultAccountPrivateKey();

  // Simple contract that implements IMessageVerification.proveL2MessageInclusionShared() and always returns true
  // Solidity equivalent:
  // contract MockL2MessageVerification {
  //     function proveL2MessageInclusionShared(uint256, uint256, uint256, L2Message memory, bytes32[] calldata) external pure returns (bool) {
  //         return true;
  //     }
  // }

  // Bytecode for the above contract (compiled separately)
  // This is a minimal contract with just the proveL2MessageInclusionShared function
  const mockBytecode = "0x608060405234801561000f575f5ffd5b506101438061001d5f395ff3fe608060405234801561000f575f5ffd5b5060043610610029575f3560e01c8063b91bcc561461002d575b5f5ffd5b610047600480360381019061004291906100a3565b61005d565b6040516100549190610105565b60405180910390f35b5f60019050949350505050565b5f5ffd5b5f819050919050565b6100818161006f565b811461008b575f5ffd5b50565b5f8135905061009c81610078565b92915050565b5f5f5f5f5f60a086880312156100bb576100ba61006b565b5b5f6100c88882890161008e565b95505060206100d98882890161008e565b94505060406100ea8882890161008e565b93505060606100fb8882890161008e565b9250506080860135905092959194509250565b5f8115159050919050565b6101228161010e565b82525050565b5f60208201905061013b5f830184610119565b9291505056fea26469706673582212209ac8f7bfb2e8c9f4e5c8a3b1e6d4f2c1b9e8d7c6f5a4b3e2d1c0f9e8d7c6f5a464736f6c634300081c0033";

  for (const l2Chain of state.chains.l2) {
    console.log(`Chain ${l2Chain.chainId}:`);

    const provider = new JsonRpcProvider(l2Chain.rpcUrl);

    // Deploy using anvil_setCode
    console.log(`   Deploying MockL2MessageVerification at ${L2_MESSAGE_VERIFICATION_ADDR}...`);
    await provider.send("anvil_setCode", [L2_MESSAGE_VERIFICATION_ADDR, mockBytecode]);
    console.log(`   ✅ MockL2MessageVerification deployed (always returns true)\n`);
  }

  console.log("✅ MockL2MessageVerification deployed on all chains\n");
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});
