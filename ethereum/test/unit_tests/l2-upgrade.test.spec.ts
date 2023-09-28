import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { Action, facetCut, diamondCut } from '../../src.ts/diamondCut';
import {
    DiamondInitFactory,
    AllowListFactory,
    AllowList,
    ExecutorFacet,
    ExecutorFacetFactory,
    DiamondCutFacetFactory,
    GettersFacetFactory,
    GovernanceFacetFactory,
    GettersFacet,
    GovernanceFacet,
    DefaultUpgradeFactory,
    CustomUpgradeTestFactory
} from '../../typechain';
import {
    getCallRevertReason,
    AccessMode,
    EMPTY_STRING_KECCAK,
    genesisStoredBatchInfo,
    StoredBatchInfo,
    CommitBatchInfo,
    L2_SYSTEM_CONTEXT_ADDRESS,
    L2_BOOTLOADER_ADDRESS,
    createSystemLogs,
    SYSTEM_LOG_KEYS,
    constructL2Log,
    L2_TO_L1_MESSENGER,
    packBatchTimestampAndBatchTimestamp
} from './utils';
import * as ethers from 'ethers';
import { BigNumber, BigNumberish, BytesLike } from 'ethers';
import { DiamondCutFacet } from '../../typechain';
import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT, hashBytecode } from 'zksync-web3/build/src/utils';

const SYSTEM_UPGRADE_TX_TYPE = 254;

describe('L2 upgrade test', function () {
    let proxyExecutor: ExecutorFacet;
    let proxyDiamondCut: DiamondCutFacet;
    let proxyGetters: GettersFacet;
    let proxyGovernance: GovernanceFacet;

    let allowList: AllowList;
    let diamondProxyContract: ethers.Contract;
    let owner: ethers.Signer;

    let batch1Info: CommitBatchInfo;
    let storedBatch1Info: StoredBatchInfo;

    let verifier: string;
    let verifierParams: VerifierParams;
    const noopUpgradeTransaction = buildL2CanonicalTransaction({ txType: 0 });

    before(async () => {
        [owner] = await hardhat.ethers.getSigners();

        const executorFactory = await hardhat.ethers.getContractFactory('ExecutorFacet');
        const executorContract = await executorFactory.deploy();
        const executorFacet = ExecutorFacetFactory.connect(executorContract.address, executorContract.signer);

        const gettersFactory = await hardhat.ethers.getContractFactory('GettersFacet');
        const gettersContract = await gettersFactory.deploy();
        const gettersFacet = GettersFacetFactory.connect(gettersContract.address, gettersContract.signer);

        const diamondCutFacetFactory = await hardhat.ethers.getContractFactory('DiamondCutFacet');
        const diamondCutFacetContract = await diamondCutFacetFactory.deploy();
        const diamondCutFacet = DiamondCutFacetFactory.connect(
            diamondCutFacetContract.address,
            diamondCutFacetContract.signer
        );

        const governanceFactory = await hardhat.ethers.getContractFactory('GovernanceFacet');
        const governanceContract = await governanceFactory.deploy();
        const governanceFacet = GovernanceFacetFactory.connect(governanceContract.address, governanceContract.signer);

        const allowListFactory = await hardhat.ethers.getContractFactory('AllowList');
        const allowListContract = await allowListFactory.deploy(await allowListFactory.signer.getAddress());
        allowList = AllowListFactory.connect(allowListContract.address, allowListContract.signer);

        // Note, that while this testsuit is focused on testing MailboxFaucet only,
        // we still need to initialize its storage via DiamondProxy
        const diamondInitFactory = await hardhat.ethers.getContractFactory('DiamondInit');
        const diamondInitContract = await diamondInitFactory.deploy();
        const diamondInit = DiamondInitFactory.connect(diamondInitContract.address, diamondInitContract.signer);

        const dummyHash = new Uint8Array(32);
        dummyHash.set([1, 0, 0, 1]);
        verifier = ethers.utils.hexlify(ethers.utils.randomBytes(20));
        verifierParams = {
            recursionCircuitsSetVksHash: ethers.constants.HashZero,
            recursionLeafLevelVkHash: ethers.constants.HashZero,
            recursionNodeLevelVkHash: ethers.constants.HashZero
        };
        const diamondInitData = diamondInit.interface.encodeFunctionData('initialize', [
            verifier,
            await owner.getAddress(),
            ethers.constants.HashZero,
            0,
            ethers.constants.HashZero,
            allowList.address,
            verifierParams,
            false,
            dummyHash,
            dummyHash,
            10000000
        ]);

        const facetCuts = [
            // Should be unfreezable. The function to unfreeze contract is located on the diamond cut facet.
            // That means if the diamond cut will be freezable, the proxy can NEVER be unfrozen.
            facetCut(diamondCutFacet.address, diamondCutFacet.interface, Action.Add, false),
            // Should be unfreezable. There are getters, that users can expect to be available.
            facetCut(gettersFacet.address, gettersFacet.interface, Action.Add, false),
            facetCut(executorFacet.address, executorFacet.interface, Action.Add, true),
            facetCut(governanceFacet.address, governanceFacet.interface, Action.Add, true)
        ];

        const diamondCutData = diamondCut(facetCuts, diamondInit.address, diamondInitData);

        const diamondProxyFactory = await hardhat.ethers.getContractFactory('DiamondProxy');
        const chainId = hardhat.network.config.chainId;
        diamondProxyContract = await diamondProxyFactory.deploy(chainId, diamondCutData);

        await (await allowList.setAccessMode(diamondProxyContract.address, AccessMode.Public)).wait();

        proxyExecutor = ExecutorFacetFactory.connect(diamondProxyContract.address, owner);
        proxyGetters = GettersFacetFactory.connect(diamondProxyContract.address, owner);
        proxyDiamondCut = DiamondCutFacetFactory.connect(diamondProxyContract.address, owner);
        proxyGovernance = GovernanceFacetFactory.connect(diamondProxyContract.address, owner);

        await (await proxyGovernance.setValidator(await owner.getAddress(), true)).wait();
    });

    it('Upgrade should work even if not all batches are processed', async () => {
        batch1Info = await buildCommitBatchInfo(genesisStoredBatchInfo(), {
            batchNumber: 1
        });

        const commitReceipt = await (await proxyExecutor.commitBatches(genesisStoredBatchInfo(), [batch1Info])).wait();
        const commitment = commitReceipt.events[0].args.commitment;

        expect(await proxyGetters.getProtocolVersion()).to.equal(0);
        expect(await proxyGetters.getL2SystemContractsUpgradeTxHash()).to.equal(ethers.constants.HashZero);

        await (
            await executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                newProtocolVersion: 1,
                l2ProtocolUpgradeTx: noopUpgradeTransaction
            })
        ).wait();

        expect(await proxyGetters.getProtocolVersion()).to.equal(1);

        storedBatch1Info = getBatchStoredInfo(batch1Info, commitment);

        await makeExecutedEqualCommitted(proxyExecutor, genesisStoredBatchInfo(), [storedBatch1Info], []);
    });

    it('Timestamp should behave correctly', async () => {
        // Upgrade was scheduled for now should work fine
        const timeNow = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        await executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
            upgradeTimestamp: ethers.BigNumber.from(timeNow),
            l2ProtocolUpgradeTx: noopUpgradeTransaction
        });

        // Upgrade that was scheduled for the future should not work now
        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                upgradeTimestamp: ethers.BigNumber.from(timeNow).mul(2),
                l2ProtocolUpgradeTx: noopUpgradeTransaction
            })
        );
        expect(revertReason).to.equal('Upgrade is not ready yet');

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());
    });

    it('Should require correct tx type for upgrade tx', async () => {
        const wrongTx = buildL2CanonicalTransaction({
            txType: 255
        });
        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                l2ProtocolUpgradeTx: wrongTx
            })
        );

        expect(revertReason).to.equal('L2 system upgrade tx type is wrong');

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());
    });

    it('Should include the new protocol version as part of nonce', async () => {
        const wrongTx = buildL2CanonicalTransaction({
            txType: 254,
            nonce: 0
        });

        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                l2ProtocolUpgradeTx: wrongTx,
                newProtocolVersion: 3
            })
        );

        expect(revertReason).to.equal('The new protocol version should be included in the L2 system upgrade tx');

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());
    });

    it('Should ensure monotonic protocol version', async () => {
        const wrongTx = buildL2CanonicalTransaction({
            txType: 254,
            nonce: 0
        });

        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                l2ProtocolUpgradeTx: wrongTx,
                newProtocolVersion: 0
            })
        );

        expect(revertReason).to.equal('New protocol version is not greater than the current one');

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());
    });

    it('Should validate upgrade transaction overhead', async () => {
        const wrongTx = buildL2CanonicalTransaction({
            nonce: 0,
            gasLimit: 0
        });

        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                l2ProtocolUpgradeTx: wrongTx,
                newProtocolVersion: 3
            })
        );

        expect(revertReason).to.equal('my');

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());
    });

    it('Should validate upgrade transaction gas max', async () => {
        const wrongTx = buildL2CanonicalTransaction({
            nonce: 0,
            gasLimit: 1000000000000
        });

        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                l2ProtocolUpgradeTx: wrongTx,
                newProtocolVersion: 3
            })
        );

        expect(revertReason).to.equal('ui');

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());
    });

    it('Should validate upgrade transaction cant output more pubdata than processable', async () => {
        const wrongTx = buildL2CanonicalTransaction({
            nonce: 0,
            gasLimit: 10000000,
            gasPerPubdataByteLimit: 1
        });

        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                l2ProtocolUpgradeTx: wrongTx,
                newProtocolVersion: 3
            })
        );

        expect(revertReason).to.equal('uk');

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());
    });

    it('Should validate factory deps', async () => {
        const myFactoryDep = ethers.utils.hexlify(ethers.utils.randomBytes(32));
        const wrongFactoryDepHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));
        const wrongTx = buildL2CanonicalTransaction({
            factoryDeps: [wrongFactoryDepHash],
            nonce: 3
        });

        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                l2ProtocolUpgradeTx: wrongTx,
                factoryDeps: [myFactoryDep],
                newProtocolVersion: 3
            })
        );

        expect(revertReason).to.equal('Wrong factory dep hash');

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());
    });

    it('Should validate factory deps length match', async () => {
        const myFactoryDep = ethers.utils.hexlify(ethers.utils.randomBytes(32));
        const wrongTx = buildL2CanonicalTransaction({
            factoryDeps: [],
            nonce: 3
        });

        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                l2ProtocolUpgradeTx: wrongTx,
                factoryDeps: [myFactoryDep],
                newProtocolVersion: 3
            })
        );

        expect(revertReason).to.equal('Wrong number of factory deps');

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());
    });

    it('Should validate factory deps length isnt too large', async () => {
        const myFactoryDep = ethers.utils.hexlify(ethers.utils.randomBytes(32));
        const randomDepHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));

        const wrongTx = buildL2CanonicalTransaction({
            factoryDeps: Array(33).fill(randomDepHash),
            nonce: 3
        });

        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                l2ProtocolUpgradeTx: wrongTx,
                factoryDeps: Array(33).fill(myFactoryDep),
                newProtocolVersion: 3
            })
        );

        expect(revertReason).to.equal('Factory deps can be at most 32');

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());
    });

    let l2UpgradeTxHash: string;
    it('Should successfully perform an upgrade', async () => {
        const bootloaderHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));
        const defaultAccountHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));
        const newVerifier = ethers.utils.hexlify(ethers.utils.randomBytes(20));
        const newerVerifierParams = buildVerifierParams({
            recursionNodeLevelVkHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
            recursionLeafLevelVkHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
            recursionCircuitsSetVksHash: ethers.utils.hexlify(ethers.utils.randomBytes(32))
        });

        const myFactoryDep = ethers.utils.hexlify(ethers.utils.randomBytes(32));
        const myFactoryDepHash = hashBytecode(myFactoryDep);
        const upgradeTx = buildL2CanonicalTransaction({
            factoryDeps: [myFactoryDepHash],
            nonce: 4
        });

        const upgrade = {
            bootloaderHash,
            defaultAccountHash,
            verifier: newVerifier,
            verifierParams: newerVerifierParams,
            executeUpgradeTx: true,
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: [myFactoryDep],
            newProtocolVersion: 4
        };

        const upgradeReceipt = await (await executeTransparentUpgrade(proxyGetters, proxyDiamondCut, upgrade)).wait();

        const defaultUpgradeFactory = await hardhat.ethers.getContractFactory('DefaultUpgrade');
        const upgradeEvents = upgradeReceipt.logs.map((log) => {
            // Not all events can be parsed there, but we don't care about them
            try {
                const event = defaultUpgradeFactory.interface.parseLog(log);
                const parsedArgs = event.args;
                return {
                    name: event.name,
                    args: parsedArgs
                };
            } catch (_) {}
        });
        l2UpgradeTxHash = upgradeEvents.find((event) => event.name == 'UpgradeComplete').args.l2UpgradeTxHash;

        // Now, we check that all the data was set as expected
        expect(await proxyGetters.getL2BootloaderBytecodeHash()).to.equal(bootloaderHash);
        expect(await proxyGetters.getL2DefaultAccountBytecodeHash()).to.equal(defaultAccountHash);
        expect((await proxyGetters.getVerifier()).toLowerCase()).to.equal(newVerifier.toLowerCase());
        expect(await proxyGetters.getProtocolVersion()).to.equal(4);

        const newVerifierParams = await proxyGetters.getVerifierParams();
        expect(newVerifierParams.recursionNodeLevelVkHash).to.equal(newerVerifierParams.recursionNodeLevelVkHash);
        expect(newVerifierParams.recursionLeafLevelVkHash).to.equal(newerVerifierParams.recursionLeafLevelVkHash);
        expect(newVerifierParams.recursionCircuitsSetVksHash).to.equal(newerVerifierParams.recursionCircuitsSetVksHash);

        expect(upgradeEvents[0].name).to.eq('NewProtocolVersion');
        expect(upgradeEvents[0].args.previousProtocolVersion.toString()).to.eq('2');
        expect(upgradeEvents[0].args.newProtocolVersion.toString()).to.eq('4');

        expect(upgradeEvents[1].name).to.eq('NewVerifier');
        expect(upgradeEvents[1].args.oldVerifier.toLowerCase()).to.eq(verifier.toLowerCase());
        expect(upgradeEvents[1].args.newVerifier.toLowerCase()).to.eq(newVerifier.toLowerCase());

        expect(upgradeEvents[2].name).to.eq('NewVerifierParams');
        expect(upgradeEvents[2].args.oldVerifierParams[0]).to.eq(ethers.constants.HashZero);
        expect(upgradeEvents[2].args.oldVerifierParams[1]).to.eq(ethers.constants.HashZero);
        expect(upgradeEvents[2].args.oldVerifierParams[2]).to.eq(ethers.constants.HashZero);
        expect(upgradeEvents[2].args.newVerifierParams[0]).to.eq(newerVerifierParams.recursionNodeLevelVkHash);
        expect(upgradeEvents[2].args.newVerifierParams[1]).to.eq(newerVerifierParams.recursionLeafLevelVkHash);
        expect(upgradeEvents[2].args.newVerifierParams[2]).to.eq(newerVerifierParams.recursionCircuitsSetVksHash);

        expect(upgradeEvents[3].name).to.eq('NewL2BootloaderBytecodeHash');
        expect(upgradeEvents[3].args.previousBytecodeHash).to.eq(
            '0x0100000100000000000000000000000000000000000000000000000000000000'
        );
        expect(upgradeEvents[3].args.newBytecodeHash).to.eq(bootloaderHash);

        expect(upgradeEvents[4].name).to.eq('NewL2DefaultAccountBytecodeHash');
        expect(upgradeEvents[4].args.previousBytecodeHash).to.eq(
            '0x0100000100000000000000000000000000000000000000000000000000000000'
        );
        expect(upgradeEvents[4].args.newBytecodeHash).to.eq(defaultAccountHash);
    });

    it('Should fail to upgrade when there is already a pending upgrade', async () => {
        const bootloaderHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));
        const defaultAccountHash = ethers.utils.hexlify(hashBytecode(ethers.utils.randomBytes(32)));
        const verifier = ethers.utils.hexlify(ethers.utils.randomBytes(20));
        const verifierParams = buildVerifierParams({
            recursionNodeLevelVkHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
            recursionLeafLevelVkHash: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
            recursionCircuitsSetVksHash: ethers.utils.hexlify(ethers.utils.randomBytes(32))
        });

        const myFactoryDep = ethers.utils.hexlify(ethers.utils.randomBytes(32));
        const myFactoryDepHash = hashBytecode(myFactoryDep);
        const upgradeTx = buildL2CanonicalTransaction({
            factoryDeps: [myFactoryDepHash],
            nonce: 4
        });

        const upgrade = {
            bootloaderHash,
            defaultAccountHash,
            verifier: verifier,
            verifierParams,
            executeUpgradeTx: true,
            l2ProtocolUpgradeTx: upgradeTx,
            factoryDeps: [myFactoryDep],
            newProtocolVersion: 5
        };
        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(proxyGetters, proxyDiamondCut, upgrade)
        );

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());

        expect(revertReason).to.equal('Previous upgrade has not been finalized');
    });

    it('Should require that the next commit batches contains an upgrade tx', async () => {
        if (!l2UpgradeTxHash) {
            throw new Error('Can not perform this test without l2UpgradeTxHash');
        }

        const batch2InfoNoUpgradeTx = await buildCommitBatchInfo(storedBatch1Info, {
            batchNumber: 2
        });
        const revertReason = await getCallRevertReason(
            proxyExecutor.commitBatches(storedBatch1Info, [batch2InfoNoUpgradeTx])
        );
        expect(revertReason).to.equal('b8');
    });

    it('Should ensure any additional upgrade logs go to the priority ops hash', async () => {
        if (!l2UpgradeTxHash) {
            throw new Error('Can not perform this test without l2UpgradeTxHash');
        }

        const systemLogs = createSystemLogs();
        systemLogs.push(
            constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
                l2UpgradeTxHash
            )
        );
        systemLogs.push(
            constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
                l2UpgradeTxHash
            )
        );
        systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
            ethers.utils.hexlify(storedBatch1Info.batchHash)
        );

        const batch2InfoNoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
            storedBatch1Info,
            {
                batchNumber: 2
            },
            systemLogs
        );
        const revertReason = await getCallRevertReason(
            proxyExecutor.commitBatches(storedBatch1Info, [batch2InfoNoUpgradeTx])
        );
        expect(revertReason).to.equal('kp');
    });

    it('Should fail to commit when upgrade tx hash does not match', async () => {
        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        const systemLogs = createSystemLogs();
        systemLogs.push(
            constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
                ethers.constants.HashZero
            )
        );
        systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
            ethers.utils.hexlify(storedBatch1Info.batchHash)
        );

        const batch2InfoTwoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
            storedBatch1Info,
            {
                batchNumber: 2,
                timestamp
            },
            systemLogs
        );

        const revertReason = await getCallRevertReason(
            proxyExecutor.commitBatches(storedBatch1Info, [batch2InfoTwoUpgradeTx])
        );
        expect(revertReason).to.equal('ut');
    });

    it('Should commit successfully when the upgrade tx is present', async () => {
        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        const systemLogs = createSystemLogs();
        systemLogs.push(
            constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
                l2UpgradeTxHash
            )
        );
        systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
            ethers.utils.hexlify(storedBatch1Info.batchHash)
        );

        const batch2InfoTwoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
            storedBatch1Info,
            {
                batchNumber: 2,
                timestamp
            },
            systemLogs
        );

        await (await proxyExecutor.commitBatches(storedBatch1Info, [batch2InfoTwoUpgradeTx])).wait();

        expect(await proxyGetters.getL2SystemContractsUpgradeBatchNumber()).to.equal(2);
    });

    it('Should commit successfully when batch was reverted and reupgraded', async () => {
        await (await proxyExecutor.revertBatches(1)).wait();
        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        const systemLogs = createSystemLogs();
        systemLogs.push(
            constructL2Log(
                true,
                L2_BOOTLOADER_ADDRESS,
                SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
                l2UpgradeTxHash
            )
        );
        systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
            ethers.utils.hexlify(storedBatch1Info.batchHash)
        );

        const batch2InfoTwoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
            storedBatch1Info,
            {
                batchNumber: 2,
                timestamp
            },
            systemLogs
        );

        const commitReceipt = await (
            await proxyExecutor.commitBatches(storedBatch1Info, [batch2InfoTwoUpgradeTx])
        ).wait();

        expect(await proxyGetters.getL2SystemContractsUpgradeBatchNumber()).to.equal(2);
        const commitment = commitReceipt.events[0].args.commitment;
        const newBatchStoredInfo = getBatchStoredInfo(batch2InfoTwoUpgradeTx, commitment);
        await makeExecutedEqualCommitted(proxyExecutor, storedBatch1Info, [newBatchStoredInfo], []);

        storedBatch1Info = newBatchStoredInfo;
    });

    it('Should successfully commit a sequential upgrade', async () => {
        expect(await proxyGetters.getL2SystemContractsUpgradeBatchNumber()).to.equal(0);
        await (
            await executeTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                newProtocolVersion: 5,
                l2ProtocolUpgradeTx: noopUpgradeTransaction
            })
        ).wait();

        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        const systemLogs = createSystemLogs();
        systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
            ethers.utils.hexlify(storedBatch1Info.batchHash)
        );

        const batch3InfoTwoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
            storedBatch1Info,
            {
                batchNumber: 3,
                timestamp
            },
            systemLogs
        );

        const commitReceipt = await (
            await proxyExecutor.commitBatches(storedBatch1Info, [batch3InfoTwoUpgradeTx])
        ).wait();
        const commitment = commitReceipt.events[0].args.commitment;
        const newBatchStoredInfo = getBatchStoredInfo(batch3InfoTwoUpgradeTx, commitment);

        expect(await proxyGetters.getL2SystemContractsUpgradeBatchNumber()).to.equal(0);

        await makeExecutedEqualCommitted(proxyExecutor, storedBatch1Info, [newBatchStoredInfo], []);

        storedBatch1Info = newBatchStoredInfo;

        expect(await proxyGetters.getL2SystemContractsUpgradeBatchNumber()).to.equal(0);
    });

    it('Should successfully commit custom upgrade', async () => {
        const upgradeReceipt = await (
            await executeCustomTransparentUpgrade(proxyGetters, proxyDiamondCut, {
                newProtocolVersion: 6,
                l2ProtocolUpgradeTx: noopUpgradeTransaction
            })
        ).wait();
        const customUpgradeFactory = await hardhat.ethers.getContractFactory('CustomUpgradeTest');

        const upgradeEvents = upgradeReceipt.logs.map((log) => {
            // Not all events can be parsed there, but we don't care about them
            try {
                const event = customUpgradeFactory.interface.parseLog(log);
                const parsedArgs = event.args;
                return {
                    name: event.name,
                    args: parsedArgs
                };
            } catch (_) {}
        });

        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        const systemLogs = createSystemLogs();
        systemLogs[SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY] = constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
            ethers.utils.hexlify(storedBatch1Info.batchHash)
        );

        const batch3InfoTwoUpgradeTx = await buildCommitBatchInfoWithCustomLogs(
            storedBatch1Info,
            {
                batchNumber: 4,
                timestamp
            },
            systemLogs
        );

        const commitReceipt = await (
            await proxyExecutor.commitBatches(storedBatch1Info, [batch3InfoTwoUpgradeTx])
        ).wait();
        const commitment = commitReceipt.events[0].args.commitment;
        const newBatchStoredInfo = getBatchStoredInfo(batch3InfoTwoUpgradeTx, commitment);

        await makeExecutedEqualCommitted(proxyExecutor, storedBatch1Info, [newBatchStoredInfo], []);

        storedBatch1Info = newBatchStoredInfo;

        expect(upgradeEvents[1].name).to.equal('Test');
    });
});

type CommitBatchInfoWithTimestamp = Partial<CommitBatchInfo> & {
    batchNumber: BigNumberish;
};

// An actual log should also contain shardId/isService and logIndex,
// but we don't need them for the tests
interface L2ToL1Log {
    sender: string;
    key: string;
    value: string;
}

function contextLog(timestamp: number, prevBatchHash: BytesLike): L2ToL1Log {
    return {
        sender: L2_SYSTEM_CONTEXT_ADDRESS,
        key: packBatchTimestampAndBatchTimestamp(timestamp, timestamp),
        value: ethers.utils.hexlify(prevBatchHash)
    };
}

function bootloaderLog(txHash: BytesLike): L2ToL1Log {
    return {
        sender: L2_BOOTLOADER_ADDRESS,
        key: ethers.utils.hexlify(txHash),
        value: ethers.utils.hexlify(BigNumber.from(1))
    };
}

function encodeLog(log: L2ToL1Log): string {
    return ethers.utils.hexConcat([
        `0x00000000`,
        log.sender,
        ethers.utils.hexZeroPad(log.key, 32),
        ethers.utils.hexZeroPad(log.value, 32)
    ]);
}

function encodeLogs(logs: L2ToL1Log[]) {
    const joinedLogs = ethers.utils.hexConcat(logs.map(encodeLog));
    return ethers.utils.hexConcat(['0x00000000', joinedLogs]);
}

async function buildCommitBatchInfo(
    prevInfo: StoredBatchInfo,
    info: CommitBatchInfoWithTimestamp
): Promise<CommitBatchInfo> {
    const timestamp = info.timestamp || (await hardhat.ethers.provider.getBlock('latest')).timestamp;
    let systemLogs = createSystemLogs();
    systemLogs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
        true,
        L2_SYSTEM_CONTEXT_ADDRESS,
        SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
        packBatchTimestampAndBatchTimestamp(timestamp, timestamp)
    );

    return {
        timestamp,
        indexRepeatedStorageChanges: 0,
        newStateRoot: ethers.utils.randomBytes(32),
        numberOfLayer1Txs: 0,
        priorityOperationsHash: EMPTY_STRING_KECCAK,
        systemLogs: ethers.utils.hexConcat(systemLogs),
        totalL2ToL1Pubdata: ethers.constants.HashZero,
        bootloaderHeapInitialContentsHash: ethers.utils.randomBytes(32),
        eventsQueueStateHash: ethers.utils.randomBytes(32),
        ...info
    };
}

async function buildCommitBatchInfoWithCustomLogs(
    prevInfo: StoredBatchInfo,
    info: CommitBatchInfoWithTimestamp,
    systemLogs: string[]
): Promise<CommitBatchInfo> {
    const timestamp = info.timestamp || (await hardhat.ethers.provider.getBlock('latest')).timestamp;
    systemLogs[SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY] = constructL2Log(
        true,
        L2_SYSTEM_CONTEXT_ADDRESS,
        SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
        packBatchTimestampAndBatchTimestamp(timestamp, timestamp)
    );

    return {
        timestamp,
        indexRepeatedStorageChanges: 0,
        newStateRoot: ethers.utils.randomBytes(32),
        numberOfLayer1Txs: 0,
        priorityOperationsHash: EMPTY_STRING_KECCAK,
        systemLogs: ethers.utils.hexConcat(systemLogs),
        totalL2ToL1Pubdata: ethers.constants.HashZero,
        bootloaderHeapInitialContentsHash: ethers.utils.randomBytes(32),
        eventsQueueStateHash: ethers.utils.randomBytes(32),
        ...info
    };
}

function getBatchStoredInfo(commitInfo: CommitBatchInfo, commitment: string): StoredBatchInfo {
    return {
        batchNumber: commitInfo.batchNumber,
        batchHash: commitInfo.newStateRoot,
        indexRepeatedStorageChanges: commitInfo.indexRepeatedStorageChanges,
        numberOfLayer1Txs: commitInfo.numberOfLayer1Txs,
        priorityOperationsHash: commitInfo.priorityOperationsHash,
        l2LogsTreeRoot: ethers.constants.HashZero,
        timestamp: commitInfo.timestamp,
        commitment: commitment
    };
}

interface L2CanonicalTransaction {
    txType: BigNumberish;
    from: BigNumberish;
    to: BigNumberish;
    gasLimit: BigNumberish;
    gasPerPubdataByteLimit: BigNumberish;
    maxFeePerGas: BigNumberish;
    maxPriorityFeePerGas: BigNumberish;
    paymaster: BigNumberish;
    nonce: BigNumberish;
    value: BigNumberish;
    // In the future, we might want to add some
    // new fields to the struct. The `txData` struct
    // is to be passed to account and any changes to its structure
    // would mean a breaking change to these accounts. In order to prevent this,
    // we should keep some fields as "reserved".
    // It is also recommended that their length is fixed, since
    // it would allow easier proof integration (in case we will need
    // some special circuit for preprocessing transactions).
    reserved: [BigNumberish, BigNumberish, BigNumberish, BigNumberish];
    data: BytesLike;
    signature: BytesLike;
    factoryDeps: BigNumberish[];
    paymasterInput: BytesLike;
    // Reserved dynamic type for the future use-case. Using it should be avoided,
    // But it is still here, just in case we want to enable some additional functionality.
    reservedDynamic: BytesLike;
}

function buildL2CanonicalTransaction(tx: Partial<L2CanonicalTransaction>): L2CanonicalTransaction {
    return {
        txType: SYSTEM_UPGRADE_TX_TYPE,
        from: ethers.constants.AddressZero,
        to: ethers.constants.AddressZero,
        gasLimit: 3000000,
        gasPerPubdataByteLimit: REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
        maxFeePerGas: 0,
        maxPriorityFeePerGas: 0,
        paymaster: 0,
        nonce: 0,
        value: 0,
        reserved: [0, 0, 0, 0],
        data: '0x',
        signature: '0x',
        factoryDeps: [],
        paymasterInput: '0x',
        reservedDynamic: '0x',
        ...tx
    };
}

interface VerifierParams {
    recursionNodeLevelVkHash: BytesLike;
    recursionLeafLevelVkHash: BytesLike;
    recursionCircuitsSetVksHash: BytesLike;
}

function buildVerifierParams(params: Partial<VerifierParams>): VerifierParams {
    return {
        recursionNodeLevelVkHash: ethers.constants.HashZero,
        recursionLeafLevelVkHash: ethers.constants.HashZero,
        recursionCircuitsSetVksHash: ethers.constants.HashZero,
        ...params
    };
}

interface ProposedUpgrade {
    // The tx for the upgrade call to the l2 system upgrade contract
    l2ProtocolUpgradeTx: L2CanonicalTransaction;
    factoryDeps: BytesLike[];
    executeUpgradeTx: boolean;
    bootloaderHash: BytesLike;
    defaultAccountHash: BytesLike;
    verifier: string;
    verifierParams: VerifierParams;
    l1ContractsUpgradeCalldata: BytesLike;
    postUpgradeCalldata: BytesLike;
    upgradeTimestamp: ethers.BigNumber;
    newProtocolVersion: BigNumberish;
    newAllowList: string;
}

type PartialProposedUpgrade = Partial<ProposedUpgrade>;

function buildProposeUpgrade(proposedUpgrade: PartialProposedUpgrade): ProposedUpgrade {
    const newProtocolVersion = proposedUpgrade.newProtocolVersion || 0;
    return {
        l2ProtocolUpgradeTx: buildL2CanonicalTransaction({ nonce: newProtocolVersion }),
        executeUpgradeTx: false,
        bootloaderHash: ethers.constants.HashZero,
        defaultAccountHash: ethers.constants.HashZero,
        verifier: ethers.constants.AddressZero,
        verifierParams: buildVerifierParams({}),
        l1ContractsUpgradeCalldata: '0x',
        postUpgradeCalldata: '0x',
        upgradeTimestamp: ethers.constants.Zero,
        factoryDeps: [],
        newProtocolVersion,
        newAllowList: ethers.constants.AddressZero,
        ...proposedUpgrade
    };
}

async function executeTransparentUpgrade(
    proxyGetters: GettersFacet,
    proxyDiamondCut: DiamondCutFacet,
    partialUpgrade: Partial<ProposedUpgrade>,
    contractFactory?: ethers.ethers.ContractFactory
) {
    if (partialUpgrade.newProtocolVersion == null) {
        const newVersion = (await proxyGetters.getProtocolVersion()).add(1);
        partialUpgrade.newProtocolVersion = newVersion;
    }
    const upgrade = buildProposeUpgrade(partialUpgrade);
    const proposalId = (await proxyGetters.getCurrentProposalId()).add(1);

    const defaultUpgradeFactory = contractFactory
        ? contractFactory
        : await hardhat.ethers.getContractFactory('DefaultUpgrade');

    const defaultUpgrade = await defaultUpgradeFactory.deploy();
    const diamondUpgradeInit = DefaultUpgradeFactory.connect(defaultUpgrade.address, defaultUpgrade.signer);

    const upgradeCalldata = diamondUpgradeInit.interface.encodeFunctionData('upgrade', [upgrade]);

    const diamondCutData = diamondCut([], diamondUpgradeInit.address, upgradeCalldata);

    await (await proxyDiamondCut.proposeTransparentUpgrade(diamondCutData, proposalId)).wait();

    // This promise will be handled in the tests
    return proxyDiamondCut.executeUpgrade(diamondCutData, ethers.constants.HashZero);
}

async function executeCustomTransparentUpgrade(
    proxyGetters: GettersFacet,
    proxyDiamondCut: DiamondCutFacet,
    partialUpgrade: Partial<ProposedUpgrade>,
    contractFactory?: ethers.ethers.ContractFactory
) {
    if (partialUpgrade.newProtocolVersion == null) {
        const newVersion = (await proxyGetters.getProtocolVersion()).add(1);
        partialUpgrade.newProtocolVersion = newVersion;
    }
    const upgrade = buildProposeUpgrade(partialUpgrade);
    const proposalId = (await proxyGetters.getCurrentProposalId()).add(1);

    const upgradeFactory = contractFactory
        ? contractFactory
        : await hardhat.ethers.getContractFactory('CustomUpgradeTest');

    const customUpgrade = await upgradeFactory.deploy();
    const diamondUpgradeInit = CustomUpgradeTestFactory.connect(customUpgrade.address, customUpgrade.signer);

    const upgradeCalldata = diamondUpgradeInit.interface.encodeFunctionData('upgrade', [upgrade]);

    const diamondCutData = diamondCut([], diamondUpgradeInit.address, upgradeCalldata);

    await (await proxyDiamondCut.proposeTransparentUpgrade(diamondCutData, proposalId)).wait();

    // This promise will be handled in the tests
    return proxyDiamondCut.executeUpgrade(diamondCutData, ethers.constants.HashZero);
}

async function makeExecutedEqualCommitted(
    proxyExecutor: ExecutorFacet,
    prevBatchInfo: StoredBatchInfo,
    batchesToProve: StoredBatchInfo[],
    batchesToExecute: StoredBatchInfo[]
) {
    batchesToExecute = [...batchesToProve, ...batchesToExecute];

    await (
        await proxyExecutor.proveBatches(prevBatchInfo, batchesToProve, {
            recursiveAggregationInput: [],
            serializedProof: []
        })
    ).wait();

    await (await proxyExecutor.executeBatches(batchesToExecute)).wait();
}
