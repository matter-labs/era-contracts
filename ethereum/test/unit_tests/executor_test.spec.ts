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
import { AccessMode, getCallRevertReason, requestExecute } from './utils';

const EMPTY_STRING_KECCAK = `0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`;
const DEFAULT_L2_LOGS_TREE_ROOT_HASH = `0x0000000000000000000000000000000000000000000000000000000000000000`;
const L2_SYSTEM_CONTEXT_ADDRESS = `0x000000000000000000000000000000000000800b`;
const L2_BOOTLOADER_ADDRESS = `0x0000000000000000000000000000000000008001`;
const L2_KNOWN_CODE_STORAGE_ADDRESS = `0x0000000000000000000000000000000000008004`;
const L2_TO_L1_MESSENGER = `0x0000000000000000000000000000000000008008`;

describe(`Executor tests`, function () {
    let owner: ethers.Signer;
    let validator: ethers.Signer;
    let randomSigner: ethers.Signer;
    let allowList: AllowList;
    let executor: ExecutorFacet;
    let getters: GettersFacet;
    let mailbox: MailboxFacet;
    let newCommitedBlockBlockHash: any;
    let newCommitedBlockCommitment: any;
    let currentTimestamp: number;
    let newCommitBlockInfo: any;
    let newStoredBlockInfo: any;

    const genesisStoredBlockInfo = {
        blockNumber: 0,
        blockHash: ethers.constants.HashZero,
        indexRepeatedStorageChanges: 0,
        numberOfLayer1Txs: 0,
        priorityOperationsHash: EMPTY_STRING_KECCAK,
        l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
        timestamp: 0,
        commitment: ethers.constants.HashZero
    };

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
        const storedBlockInfo = {
            blockNumber: 0,
            blockHash: ethers.utils.randomBytes(32),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: ethers.utils.randomBytes(32),
            l2LogsTreeRoot: ethers.utils.randomBytes(32),
            timestamp: 0,
            commitment: ethers.utils.randomBytes(32)
        };
        const commitBlockInfo = {
            blockNumber: 0,
            timestamp: 0,
            indexRepeatedStorageChanges: 0,
            newStateRoot: ethers.utils.randomBytes(32),
            numberOfLayer1Txs: 0,
            l2LogsTreeRoot: ethers.utils.randomBytes(32),
            priorityOperationsHash: ethers.utils.randomBytes(32),
            initialStorageChanges: `0x`,
            repeatedStorageChanges: `0x`,
            l2Logs: `0x`,
            l2ArbitraryLengthMessages: [],
            factoryDeps: []
        };

        it(`Should revert on committing by unauthorised address`, async () => {
            const revertReason = await getCallRevertReason(
                executor.connect(randomSigner).commitBlocks(storedBlockInfo, [commitBlockInfo])
            );
            expect(revertReason).equal(`1h`);
        });

        it(`Should revert on committing by unauthorised address`, async () => {
            const revertReason = await getCallRevertReason(
                executor.connect(randomSigner).proveBlocks(storedBlockInfo, [storedBlockInfo], proofInput)
            );
            expect(revertReason).equal(`1h`);
        });

        it(`Should revert on executing by unauthorised address`, async () => {
            const revertReason = await getCallRevertReason(
                executor.connect(randomSigner).executeBlocks([storedBlockInfo])
            );
            expect(revertReason).equal(`1h`);
        });
    });

    describe(`Commiting functionality`, async function () {
        before(async () => {
            currentTimestamp = (await ethers.providers.getDefaultProvider().getBlock(`latest`)).timestamp;
            newCommitBlockInfo = {
                blockNumber: 1,
                timestamp: currentTimestamp,
                indexRepeatedStorageChanges: 0,
                newStateRoot: ethers.utils.randomBytes(32),
                numberOfLayer1Txs: 0,
                l2LogsTreeRoot: ethers.constants.HashZero,
                priorityOperationsHash: EMPTY_STRING_KECCAK,
                initialStorageChanges: `0x00000000`,
                repeatedStorageChanges: `0x`,
                l2Logs: `0x`,
                l2ArbitraryLengthMessages: [],
                factoryDeps: []
            };
        });

        it(`Should revert on committing with wrong last committed block data`, async () => {
            const wrongGenesisStoredBlockInfo = Object.assign({}, genesisStoredBlockInfo);
            wrongGenesisStoredBlockInfo.timestamp = 1000; // wrong timestamp

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(wrongGenesisStoredBlockInfo, [newCommitBlockInfo])
            );
            expect(revertReason).equal(`i`);
        });

        it(`Should revert on committing with wrong order of blocks`, async () => {
            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.blockNumber = 2; //wrong block number

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`f`);
        });

        it(`Should revert on committing with wrong new block timestamp`, async () => {
            const wrongNewBlockTimestamp = ethers.utils.randomBytes(32); // correct value is 0
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                wrongNewBlockTimestamp,
                ethers.constants.HashZero
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`tb`);
        });

        it(`Should revert on committing with too small new block timestamp`, async () => {
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.constants.HashZero,
                ethers.constants.HashZero
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
            wrongNewCommitBlockInfo.timestamp = 0; // too small

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`h`);
        });

        it(`Should revert on committing with too big new block timestamp`, async () => {
            const wrongNewBlockTimestamp = `0xffffffff`; // too big
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(wrongNewBlockTimestamp, 32),
                ethers.constants.HashZero
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
            wrongNewCommitBlockInfo.timestamp = parseInt(wrongNewBlockTimestamp);

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`h1`);
        });

        it(`Should revert on committing with wrong previous blockhash`, async () => {
            const wrongPreviousBlockHash = ethers.utils.randomBytes(32); // correct value is bytes32(0)
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                wrongPreviousBlockHash
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`l`);
        });

        it(`Should revert on committing without processing system context log`, async () => {
            const wrongL2Logs = ethers.utils.hexConcat([`0x00000000`]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`by`);
        });

        it(`Should revert on committing with processing system context log twice`, async () => {
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`fx`);
        });

        it(`Should revert on committing with wrong canonical tx hash`, async () => {
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00010000`,
                L2_BOOTLOADER_ADDRESS,
                ethers.utils.randomBytes(32), //wrong canonical tx hash
                ethers.utils.hexZeroPad(`0x01`, 32)
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`t`);
        });

        it(`Should revert on committing with wrong number of layer 1 TXs`, async () => {
            const arbitraryCanonicalTxHash = ethers.utils.randomBytes(32);
            const chainedPriorityTxHash = ethers.utils.keccak256(
                ethers.utils.hexConcat([EMPTY_STRING_KECCAK, arbitraryCanonicalTxHash])
            );

            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00010000`,
                L2_BOOTLOADER_ADDRESS,
                arbitraryCanonicalTxHash,
                ethers.utils.hexZeroPad(`0x01`, 32)
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
            wrongNewCommitBlockInfo.priorityOperationsHash = chainedPriorityTxHash;
            wrongNewCommitBlockInfo.numberOfLayer1Txs = 2; // wrong number

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`ta`);
        });

        it(`Should revert on committing with wrong factory deps data`, async () => {
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00010000`,
                L2_KNOWN_CODE_STORAGE_ADDRESS,
                ethers.utils.randomBytes(32)
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
            wrongNewCommitBlockInfo.factoryDeps = [ethers.utils.randomBytes(32)];

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`k3`);
        });

        it(`Should revert on committing with wrong factory deps array length`, async () => {
            const arbitraryBytecode = ethers.utils.randomBytes(32);
            const arbitraryBytecodeHash = ethers.utils.sha256(arbitraryBytecode);
            const arbitraryBytecodeHashManipulated1 = BigNumber.from(arbitraryBytecodeHash).and(
                `0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF`
            );
            const arbitraryBytecodeHashManipulated2 = BigNumber.from(arbitraryBytecodeHashManipulated1).or(
                `0x0100000100000000000000000000000000000000000000000000000000000000`
            );

            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00010000`,
                L2_KNOWN_CODE_STORAGE_ADDRESS,
                ethers.utils.hexlify(arbitraryBytecodeHashManipulated2)
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
            wrongNewCommitBlockInfo.factoryDeps = [arbitraryBytecode, arbitraryBytecode];

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`ym`);
        });

        it(`Should revert on committing with wrong hashed message`, async () => {
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00010000`,
                L2_TO_L1_MESSENGER,
                ethers.constants.HashZero,
                ethers.utils.randomBytes(32)
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
            wrongNewCommitBlockInfo.l2ArbitraryLengthMessages = [ethers.utils.randomBytes(32)];

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`k2`);
        });

        it(`Should revert on committing with wrong number of messages`, async () => {
            const arbitraryMessage = `0xaa`;
            const arbitraryHashedMessage = ethers.utils.keccak256(arbitraryMessage);
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00010000`,
                L2_TO_L1_MESSENGER,
                ethers.constants.HashZero,
                arbitraryHashedMessage
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
            wrongNewCommitBlockInfo.l2ArbitraryLengthMessages = [arbitraryMessage, arbitraryMessage]; // wrong number

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`pl`);
        });

        it(`Should revert on committing with wrong bytecode length`, async () => {
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00010000`,
                L2_KNOWN_CODE_STORAGE_ADDRESS,
                ethers.utils.randomBytes(32)
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
            wrongNewCommitBlockInfo.factoryDeps = [ethers.utils.randomBytes(20)];

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`po`);
        });

        it(`Should revert on committing with wrong number of words in the bytecode`, async () => {
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00010000`,
                L2_KNOWN_CODE_STORAGE_ADDRESS,
                ethers.utils.randomBytes(32)
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
            wrongNewCommitBlockInfo.factoryDeps = [ethers.utils.randomBytes(64)];

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`pr`);
        });

        it(`Should revert on committing with wrong reapeated storage writes`, async () => {
            const wrongL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero
            ]);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;
            wrongNewCommitBlockInfo.indexRepeatedStorageChanges = 0; // wrong value, it should be 1
            wrongNewCommitBlockInfo.initialStorageChanges = `0x00000001`;

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`yq`);
        });

        it(`Should revert on committing with too long L2 logs`, async () => {
            // uint256 constant MAX_L2_TO_L1_LOGS_COMMITMENT_BYTES = 4 + L2_TO_L1_LOG_SERIALIZE_SIZE * 512;
            const arr1 = Array(512)
                .fill([
                    `0x00000000`,
                    ethers.constants.AddressZero,
                    ethers.constants.HashZero,
                    ethers.constants.HashZero
                ])
                .flat();

            const arr2 = [
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero
            ].concat(arr1);

            const wrongL2Logs = ethers.utils.hexConcat(arr2);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = wrongL2Logs;

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`pu`);
        });

        it(`Should revert on committing with too long reapeated storage changes`, async () => {
            const correctL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero
            ]);

            // uint256 constant MAX_REPEATED_STORAGE_CHANGES_COMMITMENT_BYTES = 4 + REPEATED_STORAGE_CHANGE_SERIALIZE_SIZE * 7564;
            const arr1 = Array(7565).fill(ethers.utils.randomBytes(40)).flat();
            const arr2 = [`0x00000000`].concat(arr1);
            const wrongRepeatedStorageChanges = ethers.utils.hexConcat(arr2);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = correctL2Logs;
            wrongNewCommitBlockInfo.repeatedStorageChanges = wrongRepeatedStorageChanges; // too long repeated storage changes

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`py`);
        });

        it(`Should revert on committing with too long initial storage changes`, async () => {
            const correctL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero
            ]);

            // uint256 constant MAX_INITIAL_STORAGE_CHANGES_COMMITMENT_BYTES = 4 + INITIAL_STORAGE_CHANGE_SERIALIZE_SIZE * 4765;
            const arr1 = Array(4766).fill(ethers.utils.randomBytes(64));
            const arr2 = [`0x00000000`].concat(arr1);
            const wrongInitialStorageChanges = ethers.utils.hexConcat(arr2);

            const wrongNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            wrongNewCommitBlockInfo.l2Logs = correctL2Logs;
            wrongNewCommitBlockInfo.initialStorageChanges = wrongInitialStorageChanges; // too long initial storage changes

            const revertReason = await getCallRevertReason(
                executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [wrongNewCommitBlockInfo])
            );
            expect(revertReason).equal(`pf`);
        });

        it(`Should successfully commit a block`, async () => {
            const correctL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero
            ]);

            const correctNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            correctNewCommitBlockInfo.l2Logs = correctL2Logs;

            const commitTx = await executor
                .connect(validator)
                .commitBlocks(genesisStoredBlockInfo, [correctNewCommitBlockInfo]);

            const result = await commitTx.wait();

            newCommitedBlockBlockHash = result.events[0].args.blockHash;
            newCommitedBlockCommitment = result.events[0].args.commitment;

            expect(await getters.getTotalBlocksCommitted()).equal(1);
        });
    });

    describe(`Proving functionality`, async function () {
        before(async () => {
            newStoredBlockInfo = {
                blockNumber: 1,
                blockHash: newCommitedBlockBlockHash,
                indexRepeatedStorageChanges: 0,
                numberOfLayer1Txs: 0,
                priorityOperationsHash: EMPTY_STRING_KECCAK,
                l2LogsTreeRoot: ethers.constants.HashZero,
                timestamp: currentTimestamp,
                commitment: newCommitedBlockCommitment
            };
        });

        it(`Should revert on proving with wrong previous block data`, async () => {
            const wrongPreviousStoredBlockInfo = Object.assign({}, genesisStoredBlockInfo);
            wrongPreviousStoredBlockInfo.blockNumber = 10; // Correct is 0

            const revertReason = await getCallRevertReason(
                executor.connect(validator).proveBlocks(wrongPreviousStoredBlockInfo, [newStoredBlockInfo], proofInput)
            );
            expect(revertReason).equal(`t1`);
        });

        it(`Should revert on proving with wrong committed block`, async () => {
            const wrongNewStoredBlockInfo = Object.assign({}, newStoredBlockInfo);
            wrongNewStoredBlockInfo.blockNumber = 10; // Correct is 1

            const revertReason = await getCallRevertReason(
                executor.connect(validator).proveBlocks(genesisStoredBlockInfo, [wrongNewStoredBlockInfo], proofInput)
            );
            expect(revertReason).equal(`o1`);
        });

        it(`Should not allow proving a reverted block without commiting again`, async () => {
            await executor.connect(validator).revertBlocks(0);

            const revertReason = await getCallRevertReason(
                executor.connect(validator).proveBlocks(genesisStoredBlockInfo, [newStoredBlockInfo], proofInput)
            );
            expect(revertReason).equal(`q`);
        });

        it(`Should prove successfuly`, async () => {
            const correctL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero
            ]);

            const correctNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            correctNewCommitBlockInfo.l2Logs = correctL2Logs;

            await executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [correctNewCommitBlockInfo]);

            await executor.connect(validator).proveBlocks(genesisStoredBlockInfo, [newStoredBlockInfo], proofInput);
            expect(await getters.getTotalBlocksVerified()).equal(1);
        });
    });

    describe(`Reverting blocks functionality`, async function () {
        it(`Should not allow reverting more blocks than already committed`, async () => {
            const revertReason = await getCallRevertReason(executor.connect(validator).revertBlocks(10));
            expect(revertReason).equal(`v1`);
        });
    });

    describe(`Executing functionality`, async function () {
        it(`Should revert on executing a block with wrong block number`, async () => {
            const wrongNewStoredBlockInfo = Object.assign({}, newStoredBlockInfo);
            wrongNewStoredBlockInfo.blockNumber = 10; // correct is 1

            const revertReason = await getCallRevertReason(
                executor.connect(validator).executeBlocks([wrongNewStoredBlockInfo])
            );
            expect(revertReason).equal(`k`);
        });

        it(`Should revert on executing a block with wrong data`, async () => {
            const wrongNewStoredBlockInfo = Object.assign({}, newStoredBlockInfo);
            wrongNewStoredBlockInfo.timestamp = 0; // incorrect data

            const revertReason = await getCallRevertReason(
                executor.connect(validator).executeBlocks([wrongNewStoredBlockInfo])
            );
            expect(revertReason).equal(`exe10`);
        });

        it(`Should revert on executing a reverted block without committing and proving again`, async () => {
            await executor.connect(validator).revertBlocks(0);

            const revertReason = await getCallRevertReason(
                executor.connect(validator).executeBlocks([newStoredBlockInfo])
            );
            expect(revertReason).equal(`n`);
        });

        it(`Should revert on executing with unavailable prioirty operation hash`, async () => {
            const arbitraryCanonicalTxHash = ethers.utils.randomBytes(32);
            const chainedPriorityTxHash = ethers.utils.keccak256(
                ethers.utils.hexConcat([EMPTY_STRING_KECCAK, arbitraryCanonicalTxHash])
            );

            const correctL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00010000`,
                L2_BOOTLOADER_ADDRESS,
                arbitraryCanonicalTxHash,
                ethers.utils.hexZeroPad(`0x01`, 32)
            ]);

            const correctNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            correctNewCommitBlockInfo.l2Logs = correctL2Logs;
            correctNewCommitBlockInfo.priorityOperationsHash = chainedPriorityTxHash;
            correctNewCommitBlockInfo.numberOfLayer1Txs = 1;

            const commitTx = await executor
                .connect(validator)
                .commitBlocks(genesisStoredBlockInfo, [correctNewCommitBlockInfo]);

            const result = await commitTx.wait();

            const correctNewStoredBlockInfo = Object.assign({}, newStoredBlockInfo);
            correctNewStoredBlockInfo.blockHash = result.events[0].args.blockHash;
            correctNewStoredBlockInfo.numberOfLayer1Txs = 1;
            correctNewStoredBlockInfo.priorityOperationsHash = chainedPriorityTxHash;
            correctNewStoredBlockInfo.commitment = result.events[0].args.commitment;

            await executor
                .connect(validator)
                .proveBlocks(genesisStoredBlockInfo, [correctNewStoredBlockInfo], proofInput);

            const revertReason = await getCallRevertReason(
                executor.connect(validator).executeBlocks([correctNewStoredBlockInfo])
            );
            expect(revertReason).equal(`s`);

            await executor.connect(validator).revertBlocks(0);
        });

        it(`Should revert on executing with unmatched prioirty operation hash`, async () => {
            const arbitraryCanonicalTxHash = ethers.utils.randomBytes(32);
            const chainedPriorityTxHash = ethers.utils.keccak256(
                ethers.utils.hexConcat([EMPTY_STRING_KECCAK, arbitraryCanonicalTxHash])
            );

            const correctL2Logs = ethers.utils.hexConcat([
                `0x00000002`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero,
                `0x00010000`,
                L2_BOOTLOADER_ADDRESS,
                arbitraryCanonicalTxHash,
                ethers.utils.hexZeroPad(`0x01`, 32)
            ]);

            const correctNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            correctNewCommitBlockInfo.l2Logs = correctL2Logs;
            correctNewCommitBlockInfo.priorityOperationsHash = chainedPriorityTxHash;
            correctNewCommitBlockInfo.numberOfLayer1Txs = 1;

            const commitTx = await executor
                .connect(validator)
                .commitBlocks(genesisStoredBlockInfo, [correctNewCommitBlockInfo]);

            const result = await commitTx.wait();

            const correctNewStoredBlockInfo = Object.assign({}, newStoredBlockInfo);
            correctNewStoredBlockInfo.blockHash = result.events[0].args.blockHash;
            correctNewStoredBlockInfo.numberOfLayer1Txs = 1;
            correctNewStoredBlockInfo.priorityOperationsHash = chainedPriorityTxHash;
            correctNewStoredBlockInfo.commitment = result.events[0].args.commitment;

            await executor
                .connect(validator)
                .proveBlocks(genesisStoredBlockInfo, [correctNewStoredBlockInfo], proofInput);

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
                executor.connect(validator).executeBlocks([correctNewStoredBlockInfo])
            );
            expect(revertReason).equal(`x`);

            await executor.connect(validator).revertBlocks(0);
        });

        it(`Should execute a block successfully`, async () => {
            const correctL2Logs = ethers.utils.hexConcat([
                `0x00000001`,
                `0x00000000`,
                L2_SYSTEM_CONTEXT_ADDRESS,
                ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
                ethers.constants.HashZero
            ]);

            const correctNewCommitBlockInfo = Object.assign({}, newCommitBlockInfo);
            correctNewCommitBlockInfo.l2Logs = correctL2Logs;

            await executor.connect(validator).commitBlocks(genesisStoredBlockInfo, [correctNewCommitBlockInfo]);
            await executor.connect(validator).proveBlocks(genesisStoredBlockInfo, [newStoredBlockInfo], proofInput);
            await executor.connect(validator).executeBlocks([newStoredBlockInfo]);

            expect(await getters.getTotalBlocksExecuted()).equal(1);
        });
    });
});
