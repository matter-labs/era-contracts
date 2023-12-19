import { expect } from "chai";
import { ethers } from "ethers";
import * as hardhat from "hardhat";
import type { DummyExecutor, ValidatorTimelock } from "../../typechain";
import { DummyExecutorFactory, ValidatorTimelockFactory } from "../../typechain";
import { getCallRevertReason } from "./utils";

describe("ValidatorTimelock tests", function () {
  let owner: ethers.Signer;
  let validator: ethers.Signer;
  let randomSigner: ethers.Signer;
  let validatorTimelock: ValidatorTimelock;
  let dummyExecutor: DummyExecutor;

  const MOCK_PROOF_INPUT = {
    recursiveAggregationInput: [],
    serializedProof: [],
  };

  function getMockCommitBatchInfo(batchNumber: number, timestamp: number = 0) {
    return {
      batchNumber,
      timestamp,
      indexRepeatedStorageChanges: 0,
      newStateRoot: ethers.constants.HashZero,
      numberOfLayer1Txs: 0,
      priorityOperationsHash: ethers.constants.HashZero,
      bootloaderHeapInitialContentsHash: ethers.utils.randomBytes(32),
      eventsQueueStateHash: ethers.utils.randomBytes(32),
      systemLogs: [],
      totalL2ToL1Pubdata: "0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563",
    };
  }

  function getMockStoredBatchInfo(batchNumber: number, timestamp: number = 0) {
    return {
      batchNumber,
      batchHash: ethers.constants.HashZero,
      indexRepeatedStorageChanges: 0,
      numberOfLayer1Txs: 0,
      priorityOperationsHash: ethers.constants.HashZero,
      l2LogsTreeRoot: ethers.constants.HashZero,
      timestamp,
      commitment: ethers.constants.HashZero,
    };
  }

  before(async () => {
    [owner, validator, randomSigner] = await hardhat.ethers.getSigners();

    const dummyExecutorFactory = await hardhat.ethers.getContractFactory("DummyExecutor");
    const dummyExecutorContract = await dummyExecutorFactory.deploy();
    dummyExecutor = DummyExecutorFactory.connect(dummyExecutorContract.address, dummyExecutorContract.signer);

    const validatorTimelockFactory = await hardhat.ethers.getContractFactory("ValidatorTimelock");
    const validatorTimelockContract = await validatorTimelockFactory.deploy(
      await owner.getAddress(),
      dummyExecutor.address,
      0,
      ethers.constants.AddressZero
    );
    validatorTimelock = ValidatorTimelockFactory.connect(
      validatorTimelockContract.address,
      validatorTimelockContract.signer
    );
  });

  it("Should revert if non-validator commits batches", async () => {
    const revertReason = await getCallRevertReason(
      validatorTimelock.connect(randomSigner).commitBatches(getMockStoredBatchInfo(0), [getMockCommitBatchInfo(1)])
    );

    expect(revertReason).equal("8h");
  });

  it("Should revert if non-validator proves batches", async () => {
    const revertReason = await getCallRevertReason(
      validatorTimelock
        .connect(randomSigner)
        .proveBatches(getMockStoredBatchInfo(0), [getMockStoredBatchInfo(1)], MOCK_PROOF_INPUT)
    );

    expect(revertReason).equal("8h");
  });

  it("Should revert if non-validator revert batches", async () => {
    const revertReason = await getCallRevertReason(validatorTimelock.connect(randomSigner).revertBatches(1));

    expect(revertReason).equal("8h");
  });

  it("Should revert if non-validator executes batches", async () => {
    const revertReason = await getCallRevertReason(
      validatorTimelock.connect(randomSigner).executeBatches([getMockStoredBatchInfo(1)])
    );

    expect(revertReason).equal("8h");
  });

  it("Should revert if non-owner sets validator", async () => {
    const revertReason = await getCallRevertReason(
      validatorTimelock.connect(randomSigner).setValidator(await randomSigner.getAddress())
    );

    expect(revertReason).equal("Ownable: caller is not the owner");
  });

  it("Should revert if non-owner sets execution delay", async () => {
    const revertReason = await getCallRevertReason(validatorTimelock.connect(randomSigner).setExecutionDelay(1000));

    expect(revertReason).equal("Ownable: caller is not the owner");
  });

  it("Should successfully set the validator", async () => {
    const validatorAddress = await validator.getAddress();
    await validatorTimelock.connect(owner).setValidator(validatorAddress);

    expect(await validatorTimelock.validator()).equal(validatorAddress);
  });

  it("Should successfully set the execution delay", async () => {
    await validatorTimelock.connect(owner).setExecutionDelay(10); // set to 10 seconds

    expect(await validatorTimelock.executionDelay()).equal(10);
  });

  it("Should successfully commit batches", async () => {
    await validatorTimelock.connect(validator).commitBatches(getMockStoredBatchInfo(0), [getMockCommitBatchInfo(1)]);

    expect(await dummyExecutor.getTotalBatchesCommitted()).equal(1);
  });

  it("Should successfully prove batches", async () => {
    await validatorTimelock
      .connect(validator)
      .proveBatches(getMockStoredBatchInfo(0), [getMockStoredBatchInfo(1, 1)], MOCK_PROOF_INPUT);

    expect(await dummyExecutor.getTotalBatchesVerified()).equal(1);
  });

  it("Should revert on executing earlier than the delay", async () => {
    const revertReason = await getCallRevertReason(
      validatorTimelock.connect(validator).executeBatches([getMockStoredBatchInfo(1)])
    );

    expect(revertReason).equal("5c");
  });

  it("Should successfully revert batches", async () => {
    await validatorTimelock.connect(validator).revertBatches(0);

    expect(await dummyExecutor.getTotalBatchesVerified()).equal(0);
    expect(await dummyExecutor.getTotalBatchesCommitted()).equal(0);
  });

  it("Should successfully overwrite the committing timestamp on the reverted batches timestamp", async () => {
    const revertedBatchesTimestamp = Number(await validatorTimelock.getCommittedBatchTimestamp(1));

    await validatorTimelock.connect(validator).commitBatches(getMockStoredBatchInfo(0), [getMockCommitBatchInfo(1)]);

    await validatorTimelock
      .connect(validator)
      .proveBatches(getMockStoredBatchInfo(0), [getMockStoredBatchInfo(1)], MOCK_PROOF_INPUT);

    const newBatchesTimestamp = Number(await validatorTimelock.getCommittedBatchTimestamp(1));

    expect(newBatchesTimestamp).greaterThanOrEqual(revertedBatchesTimestamp);
  });

  it("Should successfully execute batches after the delay", async () => {
    await hardhat.network.provider.send("hardhat_mine", ["0x2", "0xc"]); //mine 2 batches with intervals of 12 seconds
    await validatorTimelock.connect(validator).executeBatches([getMockStoredBatchInfo(1)]);
    expect(await dummyExecutor.getTotalBatchesExecuted()).equal(1);
  });

  it("Should revert if validator tries to commit batches with invalid last committed batchNumber", async () => {
    const revertReason = await getCallRevertReason(
      validatorTimelock.connect(validator).commitBatches(getMockStoredBatchInfo(0), [getMockCommitBatchInfo(2)])
    );

    // Error should be forwarded from the DummyExecutor
    expect(revertReason).equal("DummyExecutor: Invalid last committed batch number");
  });

  // Test case to check if proving batches with invalid batchNumber fails
  it("Should revert if validator tries to prove batches with invalid batchNumber", async () => {
    const revertReason = await getCallRevertReason(
      validatorTimelock
        .connect(validator)
        .proveBatches(getMockStoredBatchInfo(0), [getMockStoredBatchInfo(2, 1)], MOCK_PROOF_INPUT)
    );

    expect(revertReason).equal("DummyExecutor: Invalid previous batch number");
  });

  it("Should revert if validator tries to execute more batches than were proven", async () => {
    await hardhat.network.provider.send("hardhat_mine", ["0x2", "0xc"]); //mine 2 batches with intervals of 12 seconds
    const revertReason = await getCallRevertReason(
      validatorTimelock.connect(validator).executeBatches([getMockStoredBatchInfo(2)])
    );

    expect(revertReason).equal("DummyExecutor: Can't execute batches more than committed and proven currently");
  });

  // These tests primarily needed to make gas statistics be more accurate.

  it("Should commit multiple batches in one transaction", async () => {
    await validatorTimelock
      .connect(validator)
      .commitBatches(getMockStoredBatchInfo(1), [
        getMockCommitBatchInfo(2),
        getMockCommitBatchInfo(3),
        getMockCommitBatchInfo(4),
        getMockCommitBatchInfo(5),
        getMockCommitBatchInfo(6),
        getMockCommitBatchInfo(7),
        getMockCommitBatchInfo(8),
      ]);

    expect(await dummyExecutor.getTotalBatchesCommitted()).equal(8);
  });

  it("Should prove multiple batches in one transactions", async () => {
    for (let i = 1; i < 8; i++) {
      await validatorTimelock
        .connect(validator)
        .proveBatches(getMockStoredBatchInfo(i), [getMockStoredBatchInfo(i + 1)], MOCK_PROOF_INPUT);

      expect(await dummyExecutor.getTotalBatchesVerified()).equal(i + 1);
    }
  });

  it("Should execute multiple batches in multiple transactions", async () => {
    await hardhat.network.provider.send("hardhat_mine", ["0x2", "0xc"]); //mine 2 batches with intervals of 12 seconds
    await validatorTimelock
      .connect(validator)
      .executeBatches([
        getMockStoredBatchInfo(2),
        getMockStoredBatchInfo(3),
        getMockStoredBatchInfo(4),
        getMockStoredBatchInfo(5),
        getMockStoredBatchInfo(6),
        getMockStoredBatchInfo(7),
        getMockStoredBatchInfo(8),
      ]);

    expect(await dummyExecutor.getTotalBatchesExecuted()).equal(8);
  });
});
