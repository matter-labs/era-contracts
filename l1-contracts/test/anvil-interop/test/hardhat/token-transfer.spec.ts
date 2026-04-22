import { execSync } from "child_process";
import * as path from "path";
import { expect } from "chai";
import { BigNumber } from "ethers";
import { executeTokenTransfer } from "../../src/token-transfer";
import type { MultiChainTokenTransferParams } from "../../src/types";

const ANVIL_INTEROP_DIR = path.resolve(__dirname, "../..");

function runInteropCommand(command: string): void {
  execSync(command, {
    cwd: ANVIL_INTEROP_DIR,
    stdio: "inherit",
  });
}

describe("Anvil Interop Hardhat Integration", function () {
  this.timeout(0);

  before(() => {
    if (process.env.ANVIL_INTEROP_SKIP_SETUP === "1") {
      return;
    }
    runInteropCommand("yarn start");
    runInteropCommand("yarn deploy:test-token");
  });

  after(() => {
    if (process.env.ANVIL_INTEROP_SKIP_CLEANUP === "1") {
      return;
    }
    runInteropCommand("yarn cleanup");
  });

  it("executes full L2->L2 token transfer", async () => {
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
});
