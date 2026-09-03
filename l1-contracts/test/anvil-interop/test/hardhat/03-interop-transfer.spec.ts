import { expect } from "chai";
import { BigNumber } from "ethers";
import { executeTokenTransfer } from "../../src/token-transfer";
import type { MultiChainTokenTransferParams } from "../../src/types";

describe("03 - Interop Transfer (Direct Settlement)", function () {
  this.timeout(0);

  it("transfers tokens from chain 11 to chain 12 via InteropCenter", async () => {
    const params: MultiChainTokenTransferParams = {
      sourceChainId: 11,
      targetChainId: 12,
      amount: "10",
    };

    const result = await executeTokenTransfer({
      ...params,
      logger: (line: string) => console.log(`[interop] ${line}`),
    });

    expect(result.sourceTxHash).to.match(/^0x[0-9a-fA-F]{64}$/);
    expect(result.targetTxHash).to.match(/^0x[0-9a-fA-F]{64}$/);

    const sourceBalanceDelta = BigNumber.from(result.sourceBalanceBefore).sub(result.sourceBalanceAfter);
    const destinationBalanceDelta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);

    expect(sourceBalanceDelta.eq(result.amountWei), "source chain burned amount mismatch").to.eq(true);
    expect(destinationBalanceDelta.eq(result.amountWei), "destination chain minted amount mismatch").to.eq(true);
  });

  it("transfers tokens from chain 12 to chain 11 via InteropCenter", async () => {
    const params: MultiChainTokenTransferParams = {
      sourceChainId: 12,
      targetChainId: 11,
      amount: "5",
    };

    const result = await executeTokenTransfer({
      ...params,
      logger: (line: string) => console.log(`[interop] ${line}`),
    });

    expect(result.sourceTxHash).to.match(/^0x[0-9a-fA-F]{64}$/);
    expect(result.targetTxHash).to.match(/^0x[0-9a-fA-F]{64}$/);

    const sourceBalanceDelta = BigNumber.from(result.sourceBalanceBefore).sub(result.sourceBalanceAfter);
    const destinationBalanceDelta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);

    expect(sourceBalanceDelta.eq(result.amountWei), "source chain burned amount mismatch").to.eq(true);
    expect(destinationBalanceDelta.eq(result.amountWei), "destination chain minted amount mismatch").to.eq(true);
  });

  it("transfers tokens from chain 10 to chain 11 via InteropCenter", async () => {
    const params: MultiChainTokenTransferParams = {
      sourceChainId: 10,
      targetChainId: 11,
      amount: "3",
    };

    const result = await executeTokenTransfer({
      ...params,
      logger: (line: string) => console.log(`[interop] ${line}`),
    });

    expect(result.sourceTxHash).to.match(/^0x[0-9a-fA-F]{64}$/);
    expect(result.targetTxHash).to.match(/^0x[0-9a-fA-F]{64}$/);

    const sourceBalanceDelta = BigNumber.from(result.sourceBalanceBefore).sub(result.sourceBalanceAfter);
    const destinationBalanceDelta = BigNumber.from(result.destinationBalanceAfter).sub(result.destinationBalanceBefore);

    expect(sourceBalanceDelta.eq(result.amountWei), "source chain burned amount mismatch").to.eq(true);
    expect(destinationBalanceDelta.eq(result.amountWei), "destination chain minted amount mismatch").to.eq(true);
  });
});
