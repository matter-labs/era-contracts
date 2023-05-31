import { expect } from 'chai';
import { ethers } from 'ethers';
import * as hardhat from 'hardhat';
import { Action, diamondCut, facetCut } from '../../src.ts/diamondCut';
import {
    DiamondInitFactory,
    DiamondProxy,
    DiamondProxyFactory,
    ExecutorFacetFactory,
    GettersFacet,
    GettersFacetFactory,
    GovernanceFacetFactory,
    ValidatorTimelock,
    ValidatorTimelockFactory
} from '../../typechain';
import { getCallRevertReason } from './utils';

const EMPTY_STRING_KECCAK = `0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`;
const DEFAULT_L2_LOGS_TREE_ROOT_HASH = `0x0000000000000000000000000000000000000000000000000000000000000000`;
const L2_SYSTEM_CONTEXT_ADDRESS = `0x000000000000000000000000000000000000800b`;

describe(`ValidatorTimelock tests`, function () {
    let owner: ethers.Signer;
    let validator: ethers.Signer;
    let randomSigner: ethers.Signer;
    let validatorTimelock: ValidatorTimelock;
    let proxy: DiamondProxy;
    let getters: GettersFacet;
    let currentTimestamp: number;
    let newCommitBlockInfo: any;
    let newStoredBlockInfo: any;
    let newCommitedBlockBlockHash: any;
    let newCommitedBlockCommitment: any;

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
            dummyAddress,
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
            facetCut(gettersFacet.address, gettersFacet.interface, Action.Add, false),
            facetCut(governanceFacet.address, governanceFacet.interface, Action.Add, true),
            facetCut(executorFacet.address, executorFacet.interface, Action.Add, true)
        ];

        const diamondCutData = diamondCut(facetCuts, diamondInit.address, diamondInitData);

        const diamondProxyFactory = await hardhat.ethers.getContractFactory('DiamondProxy');
        const chainId = hardhat.network.config.chainId;
        const diamondProxyContract = await diamondProxyFactory.deploy(chainId, diamondCutData);
        proxy = DiamondProxyFactory.connect(diamondProxyContract.address, diamondProxyContract.signer);

        getters = GettersFacetFactory.connect(diamondProxyContract.address, gettersContract.signer);

        const validatorTimelockFactory = await hardhat.ethers.getContractFactory(`ValidatorTimelock`);
        const validatorTimelockContract = await validatorTimelockFactory.deploy(
            await owner.getAddress(),
            proxy.address,
            0,
            ethers.constants.AddressZero
        );
        validatorTimelock = ValidatorTimelockFactory.connect(
            validatorTimelockContract.address,
            validatorTimelockContract.signer
        );

        const governance = GovernanceFacetFactory.connect(proxy.address, owner);
        await governance.setValidator(validatorTimelock.address, true);

        currentTimestamp = (await ethers.providers.getDefaultProvider().getBlock(`latest`)).timestamp;
        const newL2Logs = ethers.utils.hexConcat([
            `0x00000001`,
            `0x00000000`,
            L2_SYSTEM_CONTEXT_ADDRESS,
            ethers.utils.hexZeroPad(ethers.utils.hexlify(currentTimestamp), 32),
            ethers.constants.HashZero
        ]);
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
            l2Logs: newL2Logs,
            l2ArbitraryLengthMessages: [],
            factoryDeps: []
        };
        newStoredBlockInfo = {
            blockNumber: 1,
            blockHash: ethers.constants.HashZero,
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: ethers.constants.HashZero,
            timestamp: currentTimestamp,
            commitment: ethers.constants.HashZero
        };
    });

    it(`Should revert if non-validator commits blocks`, async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock.connect(randomSigner).commitBlocks(genesisStoredBlockInfo, [newCommitBlockInfo])
        );

        expect(revertReason).equal('8h');
    });

    it(`Should revert if non-validator proves blocks`, async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock
                .connect(randomSigner)
                .proveBlocks(genesisStoredBlockInfo, [newStoredBlockInfo], proofInput)
        );

        expect(revertReason).equal('8h');
    });

    it(`Should revert if non-validator revert blocks`, async () => {
        const revertReason = await getCallRevertReason(validatorTimelock.connect(randomSigner).revertBlocks(1));

        expect(revertReason).equal('8h');
    });

    it(`Should revert if non-validator executes blocks`, async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock.connect(randomSigner).executeBlocks([newStoredBlockInfo])
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

    it(`Should successfuly set the validator`, async () => {
        const validatorAddress = await validator.getAddress();
        await validatorTimelock.connect(owner).setValidator(validatorAddress);

        expect(await validatorTimelock.validator()).equal(validatorAddress);
    });

    it(`Should successfuly set the execution delay`, async () => {
        await validatorTimelock.connect(owner).setExecutionDelay(10); // set to 10 seconds

        expect(await validatorTimelock.executionDelay()).equal(10);
    });

    it(`Should successfully commit blocks`, async () => {
        const commitTx = await validatorTimelock
            .connect(validator)
            .commitBlocks(genesisStoredBlockInfo, [newCommitBlockInfo]);

        const result = await commitTx.wait();

        newCommitedBlockBlockHash = result.events[0].args.blockHash;
        newCommitedBlockCommitment = result.events[0].args.commitment;

        expect(await getters.getTotalBlocksCommitted()).equal(1);
    });

    it(`Should successfully prove blocks`, async () => {
        newStoredBlockInfo.blockHash = newCommitedBlockBlockHash;
        newStoredBlockInfo.commitment = newCommitedBlockCommitment;

        await validatorTimelock
            .connect(validator)
            .proveBlocks(genesisStoredBlockInfo, [newStoredBlockInfo], proofInput);

        expect(await getters.getTotalBlocksVerified()).equal(1);
    });

    it(`Should revert on executing earlier than the delay`, async () => {
        const revertReason = await getCallRevertReason(
            validatorTimelock.connect(validator).executeBlocks([newStoredBlockInfo])
        );

        expect(revertReason).equal('5c');
    });

    it(`Should successfully revert blocks`, async () => {
        await validatorTimelock.connect(validator).revertBlocks(0);

        expect(await getters.getTotalBlocksVerified()).equal(0);
        expect(await getters.getTotalBlocksCommitted()).equal(0);
    });

    it(`Should successfully overwrite the committing timestamp on the reverted blocks timestamp`, async () => {
        const revertedBlocksTimestamp = Number(await validatorTimelock.committedBlockTimestamp(1));

        const commitTx = await validatorTimelock
            .connect(validator)
            .commitBlocks(genesisStoredBlockInfo, [newCommitBlockInfo]);

        const result = await commitTx.wait();

        newCommitedBlockBlockHash = result.events[0].args.blockHash;
        newCommitedBlockCommitment = result.events[0].args.commitment;

        newStoredBlockInfo.blockHash = newCommitedBlockBlockHash;
        newStoredBlockInfo.commitment = newCommitedBlockCommitment;

        await validatorTimelock
            .connect(validator)
            .proveBlocks(genesisStoredBlockInfo, [newStoredBlockInfo], proofInput);

        const newBlocksTimestamp = Number(await validatorTimelock.committedBlockTimestamp(1));

        expect(newBlocksTimestamp).greaterThanOrEqual(revertedBlocksTimestamp);
    });

    it(`Should successfully execute blocks after the delay`, async () => {
        await hardhat.network.provider.send('hardhat_mine', ['0x2', '0xc']); //mine 2 blocks with intervals of 12 seconds
        await validatorTimelock.connect(validator).executeBlocks([newStoredBlockInfo]);
        expect(await getters.getTotalBlocksExecuted()).equal(1);
    });
});
