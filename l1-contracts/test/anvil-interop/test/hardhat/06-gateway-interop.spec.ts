import { expect } from "chai";
import { BigNumber } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { executeTokenTransfer } from "../../src/helpers/token-transfer";
import type { MultiChainTokenTransferResult } from "../../src/core/types";
import { getChainIdsByRole } from "../../src/core/utils";

// SKIPPED (temporarily): interop is now atomic-only (public bundle publication to L1 was removed), and the
// shared TS helpers (`sendInteropBundle`/`executeBundle` in interop-helpers.ts) still speak the old public
// API — the send lacks the now-mandatory `atomicBundle` attribute and the execute passes a
// MessageInclusionProof where the contract expects an AtomicFinalityProof. Re-enable once the helpers are
// migrated to the atomic IMT flow in the tracked atomic anvil follow-up (see 13-imt-atomic-swap.spec.ts for
// the working atomic orchestration these helpers should generalize).
describe.skip("06 - Gateway Interop (GW-settled chains)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwSettledChainIds: number[];

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    gwSettledChainIds = getChainIdsByRole(state.chains.config, "gwSettled");
  });

  /**
   * Helper: execute a cross-chain token transfer between GW-settled chains and
   * verify the real value movement (source-chain burn, destination-chain mint).
   */
  async function transferTokens(params: {
    sourceChainId: number;
    targetChainId: number;
    amount: string;
    sourceTokenAddress?: string;
  }): Promise<MultiChainTokenTransferResult> {
    const { sourceChainId, targetChainId, amount } = params;

    const sourceToken = params.sourceTokenAddress || state.testTokens![sourceChainId];

    const result = await executeTokenTransfer({
      sourceChainId,
      targetChainId,
      amount,
      sourceTokenAddress: sourceToken,
      logger: (line: string) => console.log(`[gw-interop] ${line}`),
    });

    expect(result.sourceTxHash).to.not.be.null;
    expect(result.targetTxHash).to.not.be.null;

    const sourceBalanceDelta = BigNumber.from(result.sourceBalanceBefore).sub(result.sourceBalanceAfter);
    const destinationBalanceDelta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);
    expect(sourceBalanceDelta.eq(result.amountWei), "source chain burned amount mismatch").to.eq(true);
    expect(destinationBalanceDelta.eq(result.amountWei), "destination chain minted amount mismatch").to.eq(true);

    return result;
  }

  it("transfers tokens between GW-settled chains", async () => {
    await transferTokens({
      sourceChainId: gwSettledChainIds[0],
      targetChainId: gwSettledChainIds[1],
      amount: "5",
      sourceTokenAddress: state.testTokens![gwSettledChainIds[0]],
    });
  });

  it("transfers tokens in reverse direction between GW-settled chains", async () => {
    await transferTokens({
      sourceChainId: gwSettledChainIds[1],
      targetChainId: gwSettledChainIds[0],
      amount: "3",
      sourceTokenAddress: state.testTokens![gwSettledChainIds[1]],
    });
  });
});
