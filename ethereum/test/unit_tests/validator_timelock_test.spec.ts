import { expect } from 'chai';
import { ethers } from 'ethers';
import * as hardhat from 'hardhat';
import { DummyExecutor, DummyExecutorFactory, ValidatorTimelock, ValidatorTimelockFactory } from '../../typechain';
import { getCallRevertReason } from './utils';

describe(`ValidatorTimelock tests`, function () {
    let owner: ethers.Signer;
    let validator: ethers.Signer;
    let randomSigner: ethers.Signer;
    let validatorTimelock: ValidatorTimelock;
    let dummyExecutor: DummyExecutor;

    const MOCK_PROOF_INPUT = {
        recursiveAggregationInput: [],
        serializedProof: []
    };

    function getMockCommitBlockInfo(blockNumber: number, timestamp: number = 0) {
        return {
            blockNumber,
            timestamp,
            indexRepeatedStorageChanges: 0,
            newStateRoot: ethers.constants.HashZero,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: ethers.constants.HashZero,
            systemLogs: [],
            totalL2ToL1Pubdata: `0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563`
        };
    }

    function getMockStoredBlockInfo(blockNumber: number, timestamp: number = 0) {
        return {
            blockNumber,
            blockHash: ethers.constants.HashZero,
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: ethers.constants.HashZero,
            l2LogsTreeRoot: ethers.constants.HashZero,
            timestamp,
            commitment: ethers.constants.HashZero
        };
    }

    before(async () => {
        [owner, validator, randomSigner] = await hardhat.ethers.getSigners();

        const dummyExecutorFactory = await hardhat.ethers.getContractFactory(`DummyExecutor`);
        const dummyExecutorContract = await dummyExecutorFactory.deploy();
        dummyExecutor = DummyExecutorFactory.connect(dummyExecutorContract.address, dummyExecutorContract.signer);

        const validatorTimelockFactory = await hardhat.ethers.getContractFactory(`ValidatorTimelock`);
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

    it(`Should revert if non-validator commits blocks`, async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock.connect(randomSigner).commitBlocks(getMockStoredBlockInfo(0), [getMockCommitBlockInfo(1)])
        );

        expect(revertReason).equal('8h');
    });

    it(`Should revert if non-validator proves blocks`, async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock
                .connect(randomSigner)
                .proveBlocks(getMockStoredBlockInfo(0), [getMockStoredBlockInfo(1)], MOCK_PROOF_INPUT)
        );

        expect(revertReason).equal('8h');
    });

    it(`Should revert if non-validator revert blocks`, async () => {
        const revertReason = await getCallRevertReason(validatorTimelock.connect(randomSigner).revertBlocks(1));

        expect(revertReason).equal('8h');
    });

    it(`Should revert if non-validator executes blocks`, async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock.connect(randomSigner).executeBlocks([getMockStoredBlockInfo(1)])
        );

        expect(revertReason).equal('8h');
    });

    it(`Should revert if non-owner sets validator`, async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock.connect(randomSigner).setValidator(await randomSigner.getAddress())
        );

        expect(revertReason).equal('Ownable: caller is not the owner');
    });

    it(`Should revert if non-owner sets execution delay`, async () => {
        const revertReason = await getCallRevertReason(validatorTimelock.connect(randomSigner).setExecutionDelay(1000));

        expect(revertReason).equal('Ownable: caller is not the owner');
    });

    it(`Should successfully set the validator`, async () => {
        const validatorAddress = await validator.getAddress();
        await validatorTimelock.connect(owner).setValidator(validatorAddress);

        expect(await validatorTimelock.validator()).equal(validatorAddress);
    });

    it(`Should successfully set the execution delay`, async () => {
        await validatorTimelock.connect(owner).setExecutionDelay(10); // set to 10 seconds

        expect(await validatorTimelock.executionDelay()).equal(10);
    });

    it(`Should successfully commit blocks`, async () => {
        await validatorTimelock.connect(validator).commitBlocks(getMockStoredBlockInfo(0), [getMockCommitBlockInfo(1)]);

        expect(await dummyExecutor.getTotalBlocksCommitted()).equal(1);
    });

    it(`Should successfully prove blocks`, async () => {
        await validatorTimelock
            .connect(validator)
            .proveBlocks(getMockStoredBlockInfo(0), [getMockStoredBlockInfo(1, 1)], MOCK_PROOF_INPUT);

        expect(await dummyExecutor.getTotalBlocksVerified()).equal(1);
    });

    it(`Should revert on executing earlier than the delay`, async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock.connect(validator).executeBlocks([getMockStoredBlockInfo(1)])
        );

        expect(revertReason).equal('5c');
    });

    it(`Should successfully revert blocks`, async () => {
        await validatorTimelock.connect(validator).revertBlocks(0);

        expect(await dummyExecutor.getTotalBlocksVerified()).equal(0);
        expect(await dummyExecutor.getTotalBlocksCommitted()).equal(0);
    });

    it(`Should successfully overwrite the committing timestamp on the reverted blocks timestamp`, async () => {
        const revertedBlocksTimestamp = Number(await validatorTimelock.committedBlockTimestamp(1));

        await validatorTimelock.connect(validator).commitBlocks(getMockStoredBlockInfo(0), [getMockCommitBlockInfo(1)]);

        await validatorTimelock
            .connect(validator)
            .proveBlocks(getMockStoredBlockInfo(0), [getMockStoredBlockInfo(1)], MOCK_PROOF_INPUT);

        const newBlocksTimestamp = Number(await validatorTimelock.committedBlockTimestamp(1));

        expect(newBlocksTimestamp).greaterThanOrEqual(revertedBlocksTimestamp);
    });

    it(`Should successfully execute blocks after the delay`, async () => {
        await hardhat.network.provider.send('hardhat_mine', ['0x2', '0xc']); //mine 2 blocks with intervals of 12 seconds
        await validatorTimelock.connect(validator).executeBlocks([getMockStoredBlockInfo(1)]);
        expect(await dummyExecutor.getTotalBlocksExecuted()).equal(1);
    });

    it('Should revert if validator tries to commit blocks with invalid last committed blockNumber', async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock.connect(validator).commitBlocks(getMockStoredBlockInfo(0), [getMockCommitBlockInfo(2)])
        );

        // Error should be forwarded from the DummyExecutor
        expect(revertReason).equal('DummyExecutor: Invalid last committed block number');
    });

    // Test case to check if proving blocks with invalid blockNumber fails
    it('Should revert if validator tries to prove blocks with invalid blockNumber', async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock
                .connect(validator)
                .proveBlocks(getMockStoredBlockInfo(0), [getMockStoredBlockInfo(2, 1)], MOCK_PROOF_INPUT)
        );

        expect(revertReason).equal('DummyExecutor: Invalid previous block number');
    });

    it('Should revert if validator tries to execute more blocks than were proven', async () => {
        await hardhat.network.provider.send('hardhat_mine', ['0x2', '0xc']); //mine 2 blocks with intervals of 12 seconds
        const revertReason = await getCallRevertReason(
            validatorTimelock.connect(validator).executeBlocks([getMockStoredBlockInfo(2)])
        );

        expect(revertReason).equal("DummyExecutor: Can't execute blocks more than committed and proven currently");
    });

    // These tests primarily needed to make gas statistics be more accurate.

    it('Should commit multiple blocks in one transaction', async () => {
        await validatorTimelock
            .connect(validator)
            .commitBlocks(getMockStoredBlockInfo(1), [
                getMockCommitBlockInfo(2),
                getMockCommitBlockInfo(3),
                getMockCommitBlockInfo(4),
                getMockCommitBlockInfo(5),
                getMockCommitBlockInfo(6),
                getMockCommitBlockInfo(7),
                getMockCommitBlockInfo(8)
            ]);

        expect(await dummyExecutor.getTotalBlocksCommitted()).equal(8);
    });

    it('Should prove multiple blocks in one transactions', async () => {
        for (let i = 1; i < 8; i++) {
            await validatorTimelock
                .connect(validator)
                .proveBlocks(getMockStoredBlockInfo(i), [getMockStoredBlockInfo(i + 1)], MOCK_PROOF_INPUT);

            expect(await dummyExecutor.getTotalBlocksVerified()).equal(i + 1);
        }
    });

    it('Should execute multiple blocks in multiple transactions', async () => {
        await hardhat.network.provider.send('hardhat_mine', ['0x2', '0xc']); //mine 2 blocks with intervals of 12 seconds
        await validatorTimelock
            .connect(validator)
            .executeBlocks([
                getMockStoredBlockInfo(2),
                getMockStoredBlockInfo(3),
                getMockStoredBlockInfo(4),
                getMockStoredBlockInfo(5),
                getMockStoredBlockInfo(6),
                getMockStoredBlockInfo(7),
                getMockStoredBlockInfo(8)
            ]);

        expect(await dummyExecutor.getTotalBlocksExecuted()).equal(8);
    });
});
