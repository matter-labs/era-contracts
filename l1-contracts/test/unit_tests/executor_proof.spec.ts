import * as hardhat from "hardhat";
import { expect } from "chai";
import type { ExecutorProvingTest } from "../../typechain";
import { ExecutorProvingTestFactory } from "../../typechain";

describe("Executor proof helpers", function () {
  const EXPECTED_PROOF_PUBLIC_INPUT = "0xb29c9adf0177455f74d0a0f38065e77a6d425370d418cd37dbf3eaa0";
  const PUBLIC_INPUT_SHIFT = 32;

  let executor: ExecutorProvingTest;

  before(async function () {
    const factory = await hardhat.ethers.getContractFactory("ExecutorProvingTest");
    const executorContract = await factory.deploy();
    executor = ExecutorProvingTestFactory.connect(executorContract.address, executorContract.signer);
  });

  it("computes the expected proof public input from adjacent batch commitments", async () => {
    const prevCommitment = "0x8199d18dbc01ea80a635f515d6a12312daa1aa32b5404944477dcd41fd7b2bdf";
    const nextCommitment = "0x34fb9fa208735dbedb259d815c79e77427a5af4b4c3c4898a98a0a6a5f1586ad";

    const result = await executor.getBatchProofPublicInput(prevCommitment, nextCommitment);

    // The Executor emits the transition hash untruncated; PUBLIC_INPUT_SHIFT is applied by the chain's
    // verifier once it has selected the proof system. The pinned value is what the Boojum prover targets.
    expect(result.shr(PUBLIC_INPUT_SHIFT).toHexString()).to.equal(EXPECTED_PROOF_PUBLIC_INPUT);
  });
});
