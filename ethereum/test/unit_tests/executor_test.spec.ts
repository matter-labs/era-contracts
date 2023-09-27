import { expect } from 'chai';
import { BigNumber, ethers } from 'ethers';
import * as hardhat from 'hardhat';
import { Action, diamondCut, facetCut } from '../../src.ts/diamondCut';
import {
    AllowList,
    AllowListFactory,
    DiamondInitFactory,
    ExecutorFacet,
    ExecutorFacetFactory,
    GettersFacet,
    GettersFacetFactory,
    MailboxFacet,
    MailboxFacetFactory,
    GovernanceFacetFactory
} from '../../typechain';
import {
    AccessMode,
    EMPTY_STRING_KECCAK,
    L2_BOOTLOADER_ADDRESS,
    L2_SYSTEM_CONTEXT_ADDRESS,
    SYSTEM_LOG_KEYS,
    constructL2Log,
    createSystemLogs,
    genesisStoredBatchInfo,
    getCallRevertReason,
    packBatchTimestampAndBatchTimestamp,
    requestExecute
} from './utils';

describe(`Executor tests`, function () {
    let owner: ethers.Signer;
    let validator: ethers.Signer;
    let randomSigner: ethers.Signer;
    let allowList: AllowList;
    let executor: ExecutorFacet;
    let getters: GettersFacet;
    let mailbox: MailboxFacet;
    let newCommitedBatchHash: any;
    let newCommitedBatchCommitment: any;
    let currentTimestamp: number;
    let newCommitBatchInfo: any;
    let newStoredBatchInfo: any;
    let logs: any;

    const proofInput = {
        recursiveAggregationInput: [],
        serializedProof: []
    };

    before(async () => {
        [owner, validator, randomSigner] = await hardhat.ethers.getSigners();

        const executorFactory = await hardhat.ethers.getContractFactory(`ExecutorFacet`);
        const executorContract = await executorFactory.deploy();
        const executorFacet = ExecutorFacetFactory.connect(executorContract.address, executorContract.signer);

        const governanceFactory = await hardhat.ethers.getContractFactory(`GovernanceFacet`);
        const governanceContract = await governanceFactory.deploy();
        const governanceFacet = GovernanceFacetFactory.connect(governanceContract.address, governanceContract.signer);

        const gettersFactory = await hardhat.ethers.getContractFactory(`GettersFacet`);
        const gettersContract = await gettersFactory.deploy();
        const gettersFacet = GettersFacetFactory.connect(gettersContract.address, gettersContract.signer);

        const mailboxFactory = await hardhat.ethers.getContractFactory('MailboxFacet');
        const mailboxContract = await mailboxFactory.deploy();
        const mailboxFacet = MailboxFacetFactory.connect(mailboxContract.address, mailboxContract.signer);

        const allowListFactory = await hardhat.ethers.getContractFactory('AllowList');
        const allowListContract = await allowListFactory.deploy(await allowListFactory.signer.getAddress());
        allowList = AllowListFactory.connect(allowListContract.address, allowListContract.signer);

        const diamondInitFactory = await hardhat.ethers.getContractFactory('DiamondInit');
        const diamondInitContract = await diamondInitFactory.deploy();
        const diamondInit = DiamondInitFactory.connect(diamondInitContract.address, diamondInitContract.signer);

        const dummyHash = new Uint8Array(32);
        dummyHash.set([1, 0, 0, 1]);
        const dummyAddress = ethers.utils.hexlify(ethers.utils.randomBytes(20));
        const diamondInitData = diamondInit.interface.encodeFunctionData('initialize', [
            dummyAddress,
            await owner.getAddress(),
            ethers.constants.HashZero,
            0,
            ethers.constants.HashZero,
            allowList.address,
            {
                recursionCircuitsSetVksHash: ethers.constants.HashZero,
                recursionLeafLevelVkHash: ethers.constants.HashZero,
                recursionNodeLevelVkHash: ethers.constants.HashZero
            },
            false,
            dummyHash,
            dummyHash,
            100000000000
        ]);

        const facetCuts = [
            facetCut(governanceFacet.address, governanceFacet.interface, Action.Add, true),
            facetCut(executorFacet.address, executorFacet.interface, Action.Add, true),
            facetCut(gettersFacet.address, gettersFacet.interface, Action.Add, false),
            facetCut(mailboxFacet.address, mailboxFacet.interface, Action.Add, true)
        ];

        const diamondCutData = diamondCut(facetCuts, diamondInit.address, diamondInitData);

        const diamondProxyFactory = await hardhat.ethers.getContractFactory('DiamondProxy');
        const chainId = hardhat.network.config.chainId;
        const diamondProxyContract = await diamondProxyFactory.deploy(chainId, diamondCutData);

        await (await allowList.setAccessMode(diamondProxyContract.address, AccessMode.Public)).wait();

        executor = ExecutorFacetFactory.connect(diamondProxyContract.address, executorContract.signer);
        getters = GettersFacetFactory.connect(diamondProxyContract.address, gettersContract.signer);
        mailbox = MailboxFacetFactory.connect(diamondProxyContract.address, mailboxContract.signer);

        const governance = GovernanceFacetFactory.connect(diamondProxyContract.address, owner);
        await governance.setValidator(await validator.getAddress(), true);
    });

    describe(`Authorization check`, function () {
        const storedBatchInfo = {
            batchNumber: 0,
            batchHash: ethers.utils.randomBytes(32),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: ethers.utils.randomBytes(32),
            l2LogsTreeRoot: ethers.utils.randomBytes(32),
            timestamp: 0,
            commitment: ethers.utils.randomBytes(32)
        };
        const commitBatchInfo = {
            batchNumber: 0,
            timestamp: 0,
            indexRepeatedStorageChanges: 0,
            newStateRoot: ethers.utils.randomBytes(32),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: ethers.utils.randomBytes(32),
            bootloaderHeapInitialContentsHash: ethers.utils.randomBytes(32),
            eventsQueueStateHash: ethers.utils.randomBytes(32),
            systemLogs: `0x`,
            totalL2ToL1Pubdata: `0x`
        };

        it(`Should revert on committing by unauthorised address`, async () => {
            const revertReason = await getCallRevertReason(
                executor.connect(randomSigner).commitBatches(storedBatchInfo, [commitBatchInfo])
            );
            expect(revertReason).equal(`1h`);
        });

        it(`Should revert on proving by unauthorised address`, async () => {
            const revertReason = await getCallRevertReason(
                executor.connect(randomSigner).proveBatches(storedBatchInfo, [storedBatchInfo], proofInput)
            );
            expect(revertReason).equal(`1h`);
        });

        it(`Should revert on executing by unauthorised address`, async () => {
            const revertReason = await getCallRevertReason(
                executor.connect(randomSigner).executeBatches([storedBatchInfo])
            );
            expect(revertReason).equal(`1h`);
        });
    });

    describe(`Commiting functionality`, async function () {
        before(async () => {
            currentTimestamp = (await hardhat.ethers.providers.getDefaultProvider().getBlock(`latest`)).timestamp;
            logs = ethers.utils.hexConcat([`0x00000007`].concat(createSystemLogs()));
            newCommitBatchInfo = {
                batchNumber: 1,
                timestamp: currentTimestamp,
                indexRepeatedStorageChanges: 0,
                newStateRoot: ethers.utils.randomBytes(32),
                numberOfLayer1Txs: 0,
                priorityOperationsHash: EMPTY_STRING_KECCAK,
                bootloaderHeapInitialContentsHash: ethers.utils.randomBytes(32),
                eventsQueueStateHash: ethers.utils.randomBytes(32),
                systemLogs: logs,
                totalL2ToL1Pubdata: ethers.constants.HashZero
            };
        });

        it(`Should revert on committing with wrong last committed batch data`, async () => {
            const wrongGenesisStoredBatchInfo = Object.assign({}, genesisStoredBatchInfo());
            wrongGenesisStoredBatchInfo.timestamp = 1000; // wrong timestamp

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(wrongGenesisStoredBatchInfo, [newCommitBatchInfo])
            );
            expect(revertReason).equal(`i`);
        });

        it(`Should revert on committing with wrong order of batches`, async () => {
            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.batchNumber = 2; //wrong batch number

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`f`);
        });

        it(`Should revert on committing with wrong new batch timestamp`, async () => {
            const wrongNewBatchTimestamp = ethers.utils.hexValue(ethers.utils.randomBytes(32)); // correct value is 0
            var wrongL2Logs = createSystemLogs();
            wrongL2Logs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
                wrongNewBatchTimestamp.toString()
            );

            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(wrongL2Logs));

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`tb`);
        });

        it(`Should revert on committing with too small new batch timestamp`, async () => {
            const wrongNewBatchTimestamp = 1; // too small
            var wrongL2Logs = createSystemLogs();
            wrongL2Logs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
                ethers.utils.hexlify(
                    packBatchTimestampAndBatchTimestamp(wrongNewBatchTimestamp, wrongNewBatchTimestamp)
                )
            );

            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(wrongL2Logs));
            wrongNewCommitBatchInfo.timestamp = wrongNewBatchTimestamp;

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`h1`);
        });

        it(`Should revert on committing with too big last L2 block timestamp`, async () => {
            const wrongNewBatchTimestamp = `0xffffffff`; // too big
            var wrongL2Logs = createSystemLogs();
            wrongL2Logs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
                packBatchTimestampAndBatchTimestamp(wrongNewBatchTimestamp, wrongNewBatchTimestamp)
            );

            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(wrongL2Logs));
            wrongNewCommitBatchInfo.timestamp = parseInt(wrongNewBatchTimestamp);

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`h2`);
        });

        it(`Should revert on committing with wrong previous batchhash`, async () => {
            const wrongPreviousBatchHash = ethers.utils.randomBytes(32); // correct value is bytes32(0)
            var wrongL2Logs = createSystemLogs();
            wrongL2Logs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
                ethers.utils.hexlify(wrongPreviousBatchHash)
            );

            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(wrongL2Logs));

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`l`);
        });

        it(`Should revert on committing without processing system context log`, async () => {
            var wrongL2Logs = createSystemLogs();
            delete wrongL2Logs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY];

            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000006`].concat(wrongL2Logs));

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`b7`);
        });

        it(`Should revert on committing with processing system context log twice`, async () => {
            var wrongL2Logs = createSystemLogs();
            wrongL2Logs.push(
                constructL2Log(
                    true,
                    L2_SYSTEM_CONTEXT_ADDRESS,
                    SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
                    ethers.constants.HashZero
                )
            );

            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000008`].concat(wrongL2Logs));

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`kp`);
        });

        it('Should revert on unexpected L2->L1 log', async () => {
            // We do not expect to receive an L2->L1 log from zero address
            const unexpectedAddress = ethers.constants.AddressZero;
            var wrongL2Logs = createSystemLogs();
            wrongL2Logs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
                true,
                unexpectedAddress,
                SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
                ethers.constants.HashZero
            );

            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000008`].concat(wrongL2Logs));

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`sc`);
        });

        it(`Should revert on committing with wrong canonical tx hash`, async () => {
            var wrongChainedPriorityHash = ethers.utils.randomBytes(32);
            var wrongL2Logs = createSystemLogs();
            wrongL2Logs[SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY] = constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY,
                ethers.utils.hexlify(wrongChainedPriorityHash)
            );

            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(wrongL2Logs));

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`t`);
        });

        it(`Should revert on committing with wrong number of layer 1 TXs`, async () => {
            var wrongL2Logs = createSystemLogs();
            wrongL2Logs[SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY] = constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY,
                ethers.utils.hexlify(0x01)
            );

            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(wrongL2Logs));
            wrongNewCommitBatchInfo.numberOfLayer1Txs = 2; // wrong number

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`ta`);
        });

        it(`Should revert on committing with unknown system log key`, async () => {
            var wrongL2Logs = createSystemLogs();
            wrongL2Logs.push(constructL2Log(true, L2_SYSTEM_CONTEXT_ADDRESS, 119, ethers.constants.HashZero));

            const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000008`].concat(wrongL2Logs));

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
            );
            expect(revertReason).equal(`ul`);
        });

        it(`Should revert for system log from incorrect address`, async () => {
            var tests = [
                [ethers.constants.HashZero, 'lm'],
                [`0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563`, 'ln'],
                [ethers.constants.HashZero, 'lb'],
                [ethers.constants.HashZero, 'sc'],
                [ethers.constants.HashZero, 'sv'],
                [EMPTY_STRING_KECCAK, 'bl'],
                [ethers.constants.HashZero, 'bk']
            ];

            for (var i = 0; i < tests.length; i++) {
                var wrongL2Logs = createSystemLogs();
                var wrong_addr = ethers.utils.hexlify(ethers.utils.randomBytes(20));
                wrongL2Logs[i] = constructL2Log(true, wrong_addr, i, tests[i][0]);

                const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
                wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(wrongL2Logs));

                const revertReason = await getCallRevertReason(
                    executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
                );
                expect(revertReason).equal(tests[i][1]);
            }
        });

        it(`Should revert for system log missing`, async () => {
            for (var i = 0; i < 7; i++) {
                var l2Logs = createSystemLogs();
                delete l2Logs[i];

                const wrongNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
                wrongNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000006`].concat(l2Logs));

                const revertReason = await getCallRevertReason(
                    executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [wrongNewCommitBatchInfo])
                );
                expect(revertReason).equal('b7');
            }
        });

        it(`Should successfully commit a batch`, async () => {
            var correctL2Logs = createSystemLogs();
            correctL2Logs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
                packBatchTimestampAndBatchTimestamp(currentTimestamp, currentTimestamp)
            );

            const correctNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            correctNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(correctL2Logs));

            const commitTx = await executor
                .connect(validator)
                .commitBatches(genesisStoredBatchInfo(), [correctNewCommitBatchInfo]);

            const result = await commitTx.wait();

            newCommitedBatchHash = result.events[0].args.batchHash;
            newCommitedBatchCommitment = result.events[0].args.commitment;

            expect(await getters.getTotalBatchesCommitted()).equal(1);
        });
    });

    describe(`Proving functionality`, async function () {
        before(async () => {
            // Reusing the old timestamp
            currentTimestamp = newCommitBatchInfo.timestamp;

            newCommitBatchInfo = {
                batchNumber: 1,
                timestamp: currentTimestamp,
                indexRepeatedStorageChanges: 0,
                newStateRoot: ethers.utils.randomBytes(32),
                numberOfLayer1Txs: 0,
                priorityOperationsHash: EMPTY_STRING_KECCAK,
                bootloaderHeapInitialContentsHash: ethers.utils.randomBytes(32),
                eventsQueueStateHash: ethers.utils.randomBytes(32),
                systemLogs: logs,
                totalL2ToL1Pubdata: ethers.constants.HashZero
            };

            newStoredBatchInfo = {
                batchNumber: 1,
                batchHash: newCommitedBatchHash,
                indexRepeatedStorageChanges: 0,
                numberOfLayer1Txs: 0,
                priorityOperationsHash: EMPTY_STRING_KECCAK,
                l2LogsTreeRoot: ethers.constants.HashZero,
                timestamp: currentTimestamp,
                commitment: newCommitedBatchCommitment
            };
        });

        it(`Should revert on proving with wrong previous batch data`, async () => {
            const wrongPreviousStoredBatchInfo = Object.assign({}, genesisStoredBatchInfo());
            wrongPreviousStoredBatchInfo.batchNumber = 10; // Correct is 0

            const revertReason = await getCallRevertReason(
                executor.connect(validator).proveBatches(wrongPreviousStoredBatchInfo, [newStoredBatchInfo], proofInput)
            );
            expect(revertReason).equal(`t1`);
        });

        it(`Should revert on proving with wrong committed batch`, async () => {
            const wrongNewStoredBatchInfo = Object.assign({}, newStoredBatchInfo);
            wrongNewStoredBatchInfo.batchNumber = 10; // Correct is 1

            const revertReason = await getCallRevertReason(
                executor
                    .connect(validator)
                    .proveBatches(genesisStoredBatchInfo(), [wrongNewStoredBatchInfo], proofInput)
            );
            expect(revertReason).equal(`o1`);
        });

        it(`Should not allow proving a reverted batch without commiting again`, async () => {
            await executor.connect(validator).revertBatches(0);

            const revertReason = await getCallRevertReason(
                executor.connect(validator).proveBatches(genesisStoredBatchInfo(), [newStoredBatchInfo], proofInput)
            );
            expect(revertReason).equal(`q`);
        });

        it(`Should prove successfuly`, async () => {
            var correctL2Logs = createSystemLogs();
            correctL2Logs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
                packBatchTimestampAndBatchTimestamp(currentTimestamp, currentTimestamp)
            );

            const correctNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            correctNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(correctL2Logs));

            var commitTx = await executor
                .connect(validator)
                .commitBatches(genesisStoredBatchInfo(), [correctNewCommitBatchInfo]);

            var result = await commitTx.wait();

            newStoredBatchInfo.batchHash = result.events[0].args.batchHash;
            newStoredBatchInfo.commitment = result.events[0].args.commitment;

            await executor.connect(validator).proveBatches(genesisStoredBatchInfo(), [newStoredBatchInfo], proofInput);
            expect(await getters.getTotalBatchesVerified()).equal(1);
        });
    });

    describe(`Reverting batches functionality`, async function () {
        it(`Should not allow reverting more batches than already committed`, async () => {
            const revertReason = await getCallRevertReason(executor.connect(validator).revertBatches(10));
            expect(revertReason).equal(`v1`);
        });
    });

    describe(`Executing functionality`, async function () {
        it(`Should revert on executing a batch with wrong batch number`, async () => {
            const wrongNewStoredBatchInfo = Object.assign({}, newStoredBatchInfo);
            wrongNewStoredBatchInfo.batchNumber = 10; // correct is 1

            const revertReason = await getCallRevertReason(
                executor.connect(validator).executeBatches([wrongNewStoredBatchInfo])
            );
            expect(revertReason).equal(`k`);
        });

        it(`Should revert on executing a batch with wrong data`, async () => {
            const wrongNewStoredBatchInfo = Object.assign({}, newStoredBatchInfo);
            wrongNewStoredBatchInfo.timestamp = 0; // incorrect data

            const revertReason = await getCallRevertReason(
                executor.connect(validator).executeBatches([wrongNewStoredBatchInfo])
            );
            expect(revertReason).equal(`exe10`);
        });

        it(`Should revert on executing a reverted batch without committing and proving again`, async () => {
            await executor.connect(validator).revertBatches(0);

            const revertReason = await getCallRevertReason(
                executor.connect(validator).executeBatches([newStoredBatchInfo])
            );
            expect(revertReason).equal(`n`);
        });

        it(`Should revert on executing with unavailable prioirty operation hash`, async () => {
            const arbitraryCanonicalTxHash = ethers.utils.randomBytes(32);
            const chainedPriorityTxHash = ethers.utils.keccak256(
                ethers.utils.hexConcat([EMPTY_STRING_KECCAK, arbitraryCanonicalTxHash])
            );

            var correctL2Logs = createSystemLogs();
            correctL2Logs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
                packBatchTimestampAndBatchTimestamp(currentTimestamp, currentTimestamp)
            );
            correctL2Logs[SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY] = constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY,
                chainedPriorityTxHash
            );
            correctL2Logs[SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY] = constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY,
                '0x01'
            );

            const correctNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            correctNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(correctL2Logs));

            correctNewCommitBatchInfo.priorityOperationsHash = chainedPriorityTxHash;
            correctNewCommitBatchInfo.numberOfLayer1Txs = 1;

            const commitTx = await executor
                .connect(validator)
                .commitBatches(genesisStoredBatchInfo(), [correctNewCommitBatchInfo]);

            const result = await commitTx.wait();

            const correctNewStoredBatchInfo = Object.assign({}, newStoredBatchInfo);
            correctNewStoredBatchInfo.batchHash = result.events[0].args.batchHash;
            correctNewStoredBatchInfo.numberOfLayer1Txs = 1;
            correctNewStoredBatchInfo.priorityOperationsHash = chainedPriorityTxHash;
            correctNewStoredBatchInfo.commitment = result.events[0].args.commitment;

            await executor
                .connect(validator)
                .proveBatches(genesisStoredBatchInfo(), [correctNewStoredBatchInfo], proofInput);

            const revertReason = await getCallRevertReason(
                executor.connect(validator).executeBatches([correctNewStoredBatchInfo])
            );
            expect(revertReason).equal(`s`);

            await executor.connect(validator).revertBatches(0);
        });

        it(`Should revert on executing with unmatched prioirty operation hash`, async () => {
            const arbitraryCanonicalTxHash = ethers.utils.randomBytes(32);
            const chainedPriorityTxHash = ethers.utils.keccak256(
                ethers.utils.hexConcat([EMPTY_STRING_KECCAK, arbitraryCanonicalTxHash])
            );

            var correctL2Logs = createSystemLogs();
            correctL2Logs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
                packBatchTimestampAndBatchTimestamp(currentTimestamp, currentTimestamp)
            );
            correctL2Logs[SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY] = constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY,
                chainedPriorityTxHash
            );
            correctL2Logs[SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY] = constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY,
                '0x01'
            );

            const correctNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            correctNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(correctL2Logs));
            correctNewCommitBatchInfo.priorityOperationsHash = chainedPriorityTxHash;
            correctNewCommitBatchInfo.numberOfLayer1Txs = 1;

            const commitTx = await executor
                .connect(validator)
                .commitBatches(genesisStoredBatchInfo(), [correctNewCommitBatchInfo]);

            const result = await commitTx.wait();

            const correctNewStoredBatchInfo = Object.assign({}, newStoredBatchInfo);
            correctNewStoredBatchInfo.batchHash = result.events[0].args.batchHash;
            correctNewStoredBatchInfo.numberOfLayer1Txs = 1;
            correctNewStoredBatchInfo.priorityOperationsHash = chainedPriorityTxHash;
            correctNewStoredBatchInfo.commitment = result.events[0].args.commitment;

            await executor
                .connect(validator)
                .proveBatches(genesisStoredBatchInfo(), [correctNewStoredBatchInfo], proofInput);

            await requestExecute(
                mailbox,
                ethers.constants.AddressZero,
                ethers.utils.parseEther('10'),
                '0x',
                BigNumber.from(1000000),
                [new Uint8Array(32)],
                ethers.constants.AddressZero
            );

            const revertReason = await getCallRevertReason(
                executor.connect(validator).executeBatches([correctNewStoredBatchInfo])
            );
            expect(revertReason).equal(`x`);

            await executor.connect(validator).revertBatches(0);
        });

        it(`Should fail to commit batch with wrong previous batchhash`, async () => {
            const correctL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero
            ]);

            const correctNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            correctNewCommitBatchInfo.l2Logs = correctL2Logs;

            const batch = genesisStoredBatchInfo();
            batch.batchHash = '0x' + '1'.repeat(64);

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBatches(batch, [correctNewCommitBatchInfo])
            );
            expect(revertReason).to.equal('i');
        });

        it(`Should execute a batch successfully`, async () => {
            var correctL2Logs = createSystemLogs();
            correctL2Logs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
                true,
                L2_SYSTEM_CONTEXT_ADDRESS,
                SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
                packBatchTimestampAndBatchTimestamp(currentTimestamp, currentTimestamp)
            );

            const correctNewCommitBatchInfo = Object.assign({}, newCommitBatchInfo);
            correctNewCommitBatchInfo.systemLogs = ethers.utils.hexConcat([`0x00000007`].concat(correctL2Logs));

            await executor.connect(validator).commitBatches(genesisStoredBatchInfo(), [correctNewCommitBatchInfo]);
            await executor.connect(validator).proveBatches(genesisStoredBatchInfo(), [newStoredBatchInfo], proofInput);
            await executor.connect(validator).executeBatches([newStoredBatchInfo]);

            expect(await getters.getTotalBatchesExecuted()).equal(1);
        });
    });
});
