import { expect } from 'chai';
import * as hardhat from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';
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
    BridgeheadChainFactory,
    BridgeheadChain,
    DiamondFactory,
    GettersFacet,
    GovernanceFacet,
    DefaultUpgradeFactory,
    CustomUpgradeTestFactory
} from '../../typechain';
import {
    getCallRevertReason,
    AccessMode,
    EMPTY_STRING_KECCAK,
    genesisStoredBlockInfo,
    StoredBlockInfo,
    CommitBlockInfo,
    L2_SYSTEM_CONTEXT_ADDRESS,
    L2_BOOTLOADER_ADDRESS,
    packBatchTimestampAndBlockTimestamp
} from './utils';
import { hexlify, keccak256 } from 'ethers/lib/utils';
import * as ethers from 'ethers';
import { BigNumber, BigNumberish, Wallet, BytesLike } from 'ethers';
import { DiamondCutFacet } from '../../typechain';
import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT, hashBytecode } from 'zksync-web3/build/src/utils';

import { Deployer } from '../../src.ts/deploy';

const zeroHash = '0x0000000000000000000000000000000000000000000000000000000000000000';

const L2_BOOTLOADER_BYTECODE_HASH = "0x1000100000000000000000000000000000000000000000000000000000000000" ;
const L2_DEFAULT_ACCOUNT_BYTECODE_HASH = "0x1001000000000000000000000000000000000000000000000000000000000000";

const testConfigPath ='./test/test_config/constant';
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));
const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: 'utf-8' }));

const SYSTEM_UPGRADE_TX_TYPE = 254;

describe('L2 upgrade test', function () {
    let proxyExecutor: ExecutorFacet;
    let proxyDiamondCut: DiamondCutFacet;
    let proxyGetters: GettersFacet;
    let proxyGovernance: GovernanceFacet;

    let allowList: AllowList;
    let diamondProxyContract: ethers.Contract;
    let owner: ethers.Signer;

    let block1Info: CommitBlockInfo;
    let storedBlock1Info: StoredBlockInfo;

    let verifier: string;
    let verifierParams: VerifierParams;
    const noopUpgradeTransaction = buildL2CanonicalTransaction({ txType: 0 });
    let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 270;
    let priorityOperationsHash: string;
    let priorityOpTxHash: string;

    before(async () => {
        [owner] = await hardhat.ethers.getSigners();

        const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(
            owner.provider
        );
        const governorAddress = await deployWallet.getAddress();

        const gasPrice = await owner.provider.getGasPrice();

        const tx = {
            from: owner.getAddress(),
            to: deployWallet.address,
            value: ethers.utils.parseEther('1000'),
            nonce: owner.getTransactionCount(),
            gasLimit: 100000,
            gasPrice: gasPrice
        };

        await owner.sendTransaction(tx);

        const deployer = new Deployer({
            deployWallet,
            governorAddress,
            verbose: false,
            addresses: addressConfig,
            bootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
            defaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH
        });

        const create2Salt = ethers.utils.hexlify(ethers.utils.randomBytes(32));

        let nonce = await deployWallet.getTransactionCount();

        await deployer.deployCreate2Factory({ gasPrice, nonce });
        nonce++;

        // await deployer.deployMulticall3(create2Salt, {gasPrice, nonce});
        // nonce++;

        process.env.CONTRACTS_GENESIS_ROOT = zeroHash;
        process.env.CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX = '0';
        process.env.CONTRACTS_GENESIS_BLOCK_COMMITMENT = zeroHash;
        process.env.CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT = '72000000';
        process.env.CONTRACTS_RECURSION_NODE_LEVEL_VK_HASH = zeroHash;
        process.env.CONTRACTS_RECURSION_LEAF_LEVEL_VK_HASH = zeroHash;
        process.env.CONTRACTS_RECURSION_CIRCUITS_SET_VKS_HASH = zeroHash;

        await deployer.deployAllowList(create2Salt, { gasPrice, nonce });
        await deployer.deployBridgeheadContract(create2Salt, gasPrice);
        await deployer.deployProofSystemContract(create2Salt, gasPrice);
        await deployer.deployBridgeContracts(create2Salt, gasPrice);
        await deployer.deployWethBridgeContracts(create2Salt, gasPrice);

        const verifierParams = {
            recursionNodeLevelVkHash: zeroHash,
            recursionLeafLevelVkHash: zeroHash,
            recursionCircuitsSetVksHash: zeroHash
        };
        verifier = deployer.addresses.ProofSystem.Verifier;
        const initialDiamondCut = await deployer.initialProofSystemProxyDiamondCut();

        const proofSystem = deployer.proofSystemContract(deployWallet);

        await (await proofSystem.setParams(verifierParams, initialDiamondCut)).wait();

        await deployer.registerHyperchain(create2Salt, gasPrice);
        chainId = deployer.chainId;

        // const validatorTx = await deployer.proofChainContract(deployWallet).setValidator(await validator.getAddress(), true);
        // await validatorTx.wait();

        allowList = deployer.l1AllowList(deployWallet);

        const allowTx = await allowList.setBatchAccessMode(
            [
                deployer.addresses.Bridgehead.BridgeheadProxy,
                deployer.addresses.Bridgehead.ChainProxy,
                deployer.addresses.ProofSystem.ProofSystemProxy,
                deployer.addresses.ProofSystem.DiamondProxy,
                deployer.addresses.Bridges.ERC20BridgeProxy,
                deployer.addresses.Bridges.WethBridgeProxy
            ],
            [
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public
            ]
        );
        await allowTx.wait();

        proxyExecutor = ExecutorFacetFactory.connect(deployer.addresses.ProofSystem.DiamondProxy, deployWallet);
        proxyGetters = GettersFacetFactory.connect(deployer.addresses.ProofSystem.DiamondProxy, deployWallet);
        proxyDiamondCut = DiamondCutFacetFactory.connect(deployer.addresses.ProofSystem.DiamondProxy, deployWallet);
        proxyGovernance = GovernanceFacetFactory.connect(deployer.addresses.ProofSystem.DiamondProxy, deployWallet);

        await (await proxyGovernance.setValidator(await deployWallet.getAddress(), true)).wait();

        // bridgeheadContract = BridgeheadFactory.connect(deployer.addresses.Bridgehead.BridgeheadProxy, deployWallet);
        let bridgeheadChainContract = BridgeheadChainFactory.connect(
            deployer.addresses.Bridgehead.ChainProxy,
            deployWallet
        );

        let priorityOp = await bridgeheadChainContract.priorityQueueFrontOperation();
        priorityOpTxHash = priorityOp[0];
        priorityOperationsHash = keccak256(
            ethers.utils.defaultAbiCoder.encode(['uint256', 'uint256'], [EMPTY_STRING_KECCAK, priorityOp[0]])
        );
    });

    it('Upgrade should work even if not all blocks are processed', async () => {
        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        const l2Logs = encodeLogs([
            contextLog(timestamp, ethers.constants.HashZero),
            // bootloaderLog(l2UpgradeTxHash),
            // bootloaderLog(l2UpgradeTxHash)
            chainIdLog(priorityOpTxHash)
        ]);
        block1Info = await buildCommitBlockInfo(genesisStoredBlockInfo(), {
            blockNumber: 1,
            priorityOperationsHash: priorityOperationsHash,
            numberOfLayer1Txs: 1,
            l2Logs
        });

        const commitReceipt = await (await proxyExecutor.commitBlocks(genesisStoredBlockInfo(), [block1Info])).wait();
        const commitment = commitReceipt.events[0].args.commitment;

        expect(await proxyGetters.getProtocolVersion()).to.equal(0);
        expect(await proxyGetters.getL2SystemContractsUpgradeTxHash()).to.equal(ethers.constants.HashZero);

        await (
            await executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
                newProtocolVersion: 1,
                l2ProtocolUpgradeTx: noopUpgradeTransaction
            })
        ).wait();

        expect(await proxyGetters.getProtocolVersion()).to.equal(1);

        storedBlock1Info = getBlockStoredInfo(block1Info, commitment);

        await makeExecutedEqualCommitted(proxyExecutor, genesisStoredBlockInfo(), [storedBlock1Info], []);
    });

    it('Timestamp should behave correctly', async () => {
        // Upgrade was scheduled for now should work fine
        const timeNow = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        await executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
            upgradeTimestamp: ethers.BigNumber.from(timeNow),
            l2ProtocolUpgradeTx: noopUpgradeTransaction
        });

        // Upgrade that was scheduled for the future should not work now
        const revertReason = await getCallRevertReason(
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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

        const upgradeReceipt = await (
            await executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, upgrade)
        ).wait();

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
        expect(upgradeEvents[3].args.previousBytecodeHash).to.eq(L2_BOOTLOADER_BYTECODE_HASH);
        expect(upgradeEvents[3].args.newBytecodeHash).to.eq(bootloaderHash);

        expect(upgradeEvents[4].name).to.eq('NewL2DefaultAccountBytecodeHash');
        expect(upgradeEvents[4].args.previousBytecodeHash).to.eq(L2_DEFAULT_ACCOUNT_BYTECODE_HASH);
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
            executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, upgrade)
        );

        await proxyDiamondCut.cancelUpgradeProposal(await proxyGetters.getProposedUpgradeHash());

        expect(revertReason).to.equal('Previous upgrade has not been finalized');
    });

    it('Should require that the next commit blocks contains an upgrade tx', async () => {
        if (!l2UpgradeTxHash) {
            throw new Error('Can not perform this test without l2UpgradeTxHash');
        }

        const block2InfoNoUpgradeTx = await buildCommitBlockInfo(storedBlock1Info, {
            blockNumber: 2
        });
        const revertReason = await getCallRevertReason(
            proxyExecutor.commitBlocks(storedBlock1Info, [block2InfoNoUpgradeTx])
        );
        expect(revertReason).to.equal('bw');
    });

    it('Should ensure any additional upgrade logs go to the priority ops hash', async () => {
        if (!l2UpgradeTxHash) {
            throw new Error('Can not perform this test without l2UpgradeTxHash');
        }
        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        const l2Logs = encodeLogs([
            contextLog(timestamp, storedBlock1Info.blockHash),
            bootloaderLog(l2UpgradeTxHash),
            bootloaderLog(l2UpgradeTxHash)
        ]);

        const block2InfoNoUpgradeTx = await buildCommitBlockInfo(storedBlock1Info, {
            blockNumber: 2,
            timestamp,
            l2Logs
        });
        const revertReason = await getCallRevertReason(
            proxyExecutor.commitBlocks(storedBlock1Info, [block2InfoNoUpgradeTx])
        );
        expect(revertReason).to.equal('t');
    });

    it('Should fail to commit when upgrade tx hash does not match', async () => {
        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        const l2Logs = encodeLogs([
            contextLog(timestamp, storedBlock1Info.blockHash),
            bootloaderLog('0x' + '0'.repeat(64))
        ]);

        const block2InfoTwoUpgradeTx = await buildCommitBlockInfo(storedBlock1Info, {
            blockNumber: 2,
            timestamp,
            l2Logs
        });

        const revertReason = await getCallRevertReason(
            proxyExecutor.commitBlocks(storedBlock1Info, [block2InfoTwoUpgradeTx])
        );
        expect(revertReason).to.equal('bz');
    });

    it('Should commit successfully when the upgrade tx is present', async () => {
        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        const l2Logs = encodeLogs([contextLog(timestamp, storedBlock1Info.blockHash), bootloaderLog(l2UpgradeTxHash)]);

        const block2InfoTwoUpgradeTx = await buildCommitBlockInfo(storedBlock1Info, {
            blockNumber: 2,
            timestamp,
            l2Logs
        });

        await (await proxyExecutor.commitBlocks(storedBlock1Info, [block2InfoTwoUpgradeTx])).wait();

        expect(await proxyGetters.getL2SystemContractsUpgradeBlockNumber()).to.equal(2);
    });

    it('Should commit successfully when block was reverted and reupgraded', async () => {
        await (await proxyExecutor.revertBlocks(1)).wait();
        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;
        const l2Logs = encodeLogs([contextLog(timestamp, storedBlock1Info.blockHash), bootloaderLog(l2UpgradeTxHash)]);

        const block2InfoTwoUpgradeTx = await buildCommitBlockInfo(storedBlock1Info, {
            blockNumber: 2,
            timestamp,
            l2Logs
        });

        const commitReceipt = await (
            await proxyExecutor.commitBlocks(storedBlock1Info, [block2InfoTwoUpgradeTx])
        ).wait();

        expect(await proxyGetters.getL2SystemContractsUpgradeBlockNumber()).to.equal(2);
        const commitment = commitReceipt.events[0].args.commitment;
        const newBlockStoredInfo = getBlockStoredInfo(block2InfoTwoUpgradeTx, commitment);
        await makeExecutedEqualCommitted(proxyExecutor, storedBlock1Info, [newBlockStoredInfo], []);

        storedBlock1Info = newBlockStoredInfo;
    });

    it('Should successfully commit a sequential upgrade', async () => {
        expect(await proxyGetters.getL2SystemContractsUpgradeBlockNumber()).to.equal(0);
        await (
            await executeTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
                newProtocolVersion: 5,
                l2ProtocolUpgradeTx: noopUpgradeTransaction
            })
        ).wait();

        const timestamp = (await hardhat.ethers.provider.getBlock('latest')).timestamp;

        const block3InfoTwoUpgradeTx = await buildCommitBlockInfo(storedBlock1Info, {
            blockNumber: 3,
            timestamp
        });
        const commitReceipt = await (
            await proxyExecutor.commitBlocks(storedBlock1Info, [block3InfoTwoUpgradeTx])
        ).wait();
        const commitment = commitReceipt.events[0].args.commitment;
        const newBlockStoredInfo = getBlockStoredInfo(block3InfoTwoUpgradeTx, commitment);

        expect(await proxyGetters.getL2SystemContractsUpgradeBlockNumber()).to.equal(0);

        await makeExecutedEqualCommitted(proxyExecutor, storedBlock1Info, [newBlockStoredInfo], []);

        storedBlock1Info = newBlockStoredInfo;

        expect(await proxyGetters.getL2SystemContractsUpgradeBlockNumber()).to.equal(0);
    });

    it('Should successfully commit custom upgrade', async () => {
        const upgradeReceipt = await (
            await executeCustomTransparentUpgrade(chainId, proxyGetters, proxyDiamondCut, {
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

        const block3InfoTwoUpgradeTx = await buildCommitBlockInfo(storedBlock1Info, {
            blockNumber: 4,
            timestamp
        });
        const commitReceipt = await (
            await proxyExecutor.commitBlocks(storedBlock1Info, [block3InfoTwoUpgradeTx])
        ).wait();
        const commitment = commitReceipt.events[0].args.commitment;
        const newBlockStoredInfo = getBlockStoredInfo(block3InfoTwoUpgradeTx, commitment);

        await makeExecutedEqualCommitted(proxyExecutor, storedBlock1Info, [newBlockStoredInfo], []);

        storedBlock1Info = newBlockStoredInfo;

        expect(upgradeEvents[1].name).to.equal('Test');
    });
});

type CommitBlockInfoWithTimestamp = Partial<CommitBlockInfo> & {
    blockNumber: BigNumberish;
};

// An actual log should also contain shardId/isService and logIndex,
// but we don't need them for the tests
interface L2ToL1Log {
    sender: string;
    key: string;
    value: string;
    shardId?: number;
    isService?: boolean;
}

function contextLog(timestamp: number, prevBlockHash: BytesLike): L2ToL1Log {
    return {
        sender: L2_SYSTEM_CONTEXT_ADDRESS,
        key: packBatchTimestampAndBlockTimestamp(timestamp, timestamp),
        value: ethers.utils.hexlify(prevBlockHash)
    };
}

function bootloaderLog(txHash: BytesLike): L2ToL1Log {
    return {
        sender: L2_BOOTLOADER_ADDRESS,
        key: ethers.utils.hexlify(txHash),
        value: ethers.utils.hexlify(BigNumber.from(1))
    };
}

function chainIdLog(txHash: BytesLike): L2ToL1Log {
    return {
        sender: L2_BOOTLOADER_ADDRESS,
        key: ethers.utils.hexlify(txHash),
        value: ethers.utils.hexlify(BigNumber.from(1)),
        isService: true,
        shardId: 0
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

async function buildCommitBlockInfo(
    prevInfo: StoredBlockInfo,
    info: CommitBlockInfoWithTimestamp
): Promise<CommitBlockInfo> {
    const timestamp = info.timestamp || (await hardhat.ethers.provider.getBlock('latest')).timestamp;
    return {
        timestamp,
        indexRepeatedStorageChanges: 0,
        newStateRoot: ethers.utils.randomBytes(32),
        numberOfLayer1Txs: 0,
        l2LogsTreeRoot: ethers.constants.HashZero,
        priorityOperationsHash: EMPTY_STRING_KECCAK,
        initialStorageChanges: `0x00000000`,
        repeatedStorageChanges: `0x`,
        l2Logs: encodeLogs([contextLog(timestamp, prevInfo.blockHash)]),
        l2ArbitraryLengthMessages: [],
        factoryDeps: [],
        ...info
    };
}

function getBlockStoredInfo(commitInfo: CommitBlockInfo, commitment: string): StoredBlockInfo {
    return {
        blockNumber: commitInfo.blockNumber,
        blockHash: commitInfo.newStateRoot,
        indexRepeatedStorageChanges: commitInfo.indexRepeatedStorageChanges,
        numberOfLayer1Txs: commitInfo.numberOfLayer1Txs,
        priorityOperationsHash: commitInfo.priorityOperationsHash,
        l2LogsTreeRoot: commitInfo.l2LogsTreeRoot,
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
    chainId: BigNumberish,
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

    const upgradeCalldata = diamondUpgradeInit.interface.encodeFunctionData('upgrade', [chainId, upgrade]);

    const diamondCutData = diamondCut([], diamondUpgradeInit.address, upgradeCalldata);

    await (await proxyDiamondCut.proposeTransparentUpgrade(diamondCutData, proposalId)).wait();

    // This promise will be handled in the tests
    return proxyDiamondCut.executeUpgrade(diamondCutData, ethers.constants.HashZero);
}

async function executeCustomTransparentUpgrade(
    chainId: BigNumberish,
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

    const upgradeCalldata = diamondUpgradeInit.interface.encodeFunctionData('upgrade', [chainId, upgrade]);

    const diamondCutData = diamondCut([], diamondUpgradeInit.address, upgradeCalldata);

    await (await proxyDiamondCut.proposeTransparentUpgrade(diamondCutData, proposalId)).wait();

    // This promise will be handled in the tests
    return proxyDiamondCut.executeUpgrade(diamondCutData, ethers.constants.HashZero);
}

async function makeExecutedEqualCommitted(
    proxyExecutor: ExecutorFacet,
    prevBlockInfo: StoredBlockInfo,
    blocksToProve: StoredBlockInfo[],
    blocksToExecute: StoredBlockInfo[]
) {
    blocksToExecute = [...blocksToProve, ...blocksToExecute];

    await (
        await proxyExecutor.proveBlocks(prevBlockInfo, blocksToProve, {
            recursiveAggregationInput: [],
            serializedProof: []
        })
    ).wait();

    await (await proxyExecutor.executeBlocks(blocksToExecute)).wait();
}
