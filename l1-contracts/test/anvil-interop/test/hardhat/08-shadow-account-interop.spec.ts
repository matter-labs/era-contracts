import { expect } from "chai";
import { BigNumber, Contract, ethers, providers, Wallet } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole } from "../../src/core/utils";
import type { PrivateInteropAddresses } from "../../src/core/types";
import { executePrivateTokenTransfer } from "../../src/helpers/private-token-transfer";
import { getAbi } from "../../src/core/contracts";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import { ANVIL_DEFAULT_PRIVATE_KEY } from "../../src/core/const";

/**
 * 08 - Shadow Account Interop: B -> A -> C private transfer
 *
 * Tests origin-routed private interop where tokens must flow through
 * the origin chain. Executes a two-leg transfer: B→A then A→C.
 *
 * Chain setup:
 *   - Chain A (12): GW-settled, token origin chain
 *   - Chain B (14): GW-settled, sender chain
 *   - Chain C (13): GW-settled, destination chain
 */
describe("08 - Shadow Account Interop (B -> A -> C)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwSettledChainIds: number[];
  let privateAddresses: Record<number, PrivateInteropAddresses>;

  let chainA: number;
  let chainB: number;
  let chainC: number;
  let originTokenAddress: string;

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.testTokens || !state.privateInteropAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    privateAddresses = state.privateInteropAddresses;
    gwSettledChainIds = getChainIdsByRole(state.chains.config, "gwSettled");
    if (gwSettledChainIds.length < 3) {
      throw new Error("Need at least 3 GW-settled chains for B->A->C test (have " + gwSettledChainIds.length + ")");
    }

    chainA = gwSettledChainIds[0]; // 12 (origin)
    chainC = gwSettledChainIds[1]; // 13 (destination)
    chainB = gwSettledChainIds[2]; // 14 (sender)

    originTokenAddress = state.testTokens[chainA];

    console.log(`  Chain A (origin): ${chainA}`);
    console.log(`  Chain B (sender): ${chainB}`);
    console.log(`  Chain C (dest):   ${chainC}`);
    console.log(`  Origin token:     ${originTokenAddress}`);
  });

  it("seeds token from origin chain A to sender chain B", async () => {
    console.log(`\n  Bridging 100 tokens A(${chainA}) -> B(${chainB})...`);
    const result = await executePrivateTokenTransfer({
      sourceChainId: chainA,
      targetChainId: chainB,
      amount: "100",
      sourceTokenAddress: originTokenAddress,
      sourceAddresses: privateAddresses[chainA],
      targetAddresses: privateAddresses[chainB],
      logger: (line: string) => console.log(`  [A->B] ${line}`),
    });

    expect(result.targetTxHash).to.not.be.null;
    const delta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);
    expect(delta.eq(ethers.utils.parseUnits("100", 18)), "B should have received 100 tokens").to.eq(true);
  });

  it("executes leg 1: B -> A (return to origin)", async () => {
    const assetId = encodeNtvAssetId(chainA, originTokenAddress);
    const chainBInfo = state.chains!.l2.find((c) => c.chainId === chainB)!;
    const providerB = new providers.JsonRpcProvider(chainBInfo.rpcUrl);
    const ntvB = new Contract(privateAddresses[chainB].ntv, getAbi("L2NativeTokenVault"), providerB);
    const tokenOnB = await ntvB.tokenAddress(assetId);
    expect(tokenOnB).to.not.eq(ethers.constants.AddressZero, "Token should exist on chain B");

    console.log(`\n  Sending 10 tokens B(${chainB}) -> A(${chainA})...`);
    const result = await executePrivateTokenTransfer({
      sourceChainId: chainB,
      targetChainId: chainA,
      amount: "10",
      sourceTokenAddress: tokenOnB,
      sourceAddresses: privateAddresses[chainB],
      targetAddresses: privateAddresses[chainA],
      logger: (line: string) => console.log(`  [B->A] ${line}`),
    });

    expect(result.targetTxHash).to.not.be.null;
    const delta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);
    expect(delta.eq(ethers.utils.parseUnits("10", 18)), "A should have received 10 tokens").to.eq(true);
  });

  it("executes leg 2: A -> C (forward from origin)", async () => {
    // After leg 1, tokens are back on chain A. Forward them to chain C.
    console.log(`\n  Sending 10 tokens A(${chainA}) -> C(${chainC})...`);
    const result = await executePrivateTokenTransfer({
      sourceChainId: chainA,
      targetChainId: chainC,
      amount: "10",
      sourceTokenAddress: originTokenAddress,
      sourceAddresses: privateAddresses[chainA],
      targetAddresses: privateAddresses[chainC],
      logger: (line: string) => console.log(`  [A->C] ${line}`),
    });

    expect(result.targetTxHash).to.not.be.null;
    const delta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);
    expect(delta.eq(ethers.utils.parseUnits("10", 18)), "C should have received 10 tokens").to.eq(true);
  });

  it("verifies token exists on all three chains", async () => {
    const assetId = encodeNtvAssetId(chainA, originTokenAddress);

    for (const [label, chainId] of [["A", chainA], ["B", chainB], ["C", chainC]] as const) {
      const chain = state.chains!.l2.find((c) => c.chainId === chainId)!;
      const provider = new providers.JsonRpcProvider(chain.rpcUrl);
      const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
      const ntv = new Contract(privateAddresses[chainId].ntv, getAbi("L2NativeTokenVault"), provider);
      const tokenAddr = await ntv.tokenAddress(assetId);
      expect(tokenAddr).to.not.eq(ethers.constants.AddressZero, `Token should exist on chain ${label} (${chainId})`);
      const token = new Contract(tokenAddr, getAbi("TestnetERC20Token"), provider);
      const balance = await token.balanceOf(wallet.address);
      console.log(`  Chain ${label} (${chainId}) balance: ${ethers.utils.formatUnits(balance, 18)}`);
      expect(balance.gt(0), `Chain ${label} should have non-zero balance`).to.eq(true);
    }
    console.log(`\n  B -> A -> C transfer verified: tokens exist on all three chains`);
  });
});
