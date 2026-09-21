// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ExecutorTest} from "foundry-test/l1/unit/concrete/BatchProcessing/_Executor_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {CTMUpgradeHarness} from "foundry-test/l1/integration/utils/CTMUpgradeHarness.sol";
import {
    TEST_CHAIN_CONFIG_UPGRADE_VERSION,
    LEGACY_V33_COMMIT_ENCODING_VERSION,
    LEGACY_V33_COMMITMENT_FACETS_PATH
} from "foundry-test/TestConstants.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {PublishFactoryDepsResult} from "deploy-scripts/utils/bytecode/BytecodePublisher.s.sol";
import {UpgradeHelperLib} from "deploy-scripts/upgrade/default-upgrade/UpgradeHelperLib.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ICommitter, CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProposedUpgradeLib, ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {BaseZkSyncUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {DefaultUpgradeZKsyncOS} from "contracts/upgrades/DefaultUpgradeZKsyncOS.sol";
import {NotAllBatchesExecuted} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {
    L2DACommitmentScheme,
    PubdataContent,
    ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT,
    ZKSYNC_OS_FRI_PROOF_VERIFICATION_DISABLED
} from "contracts/common/Config.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

struct LegacyV33CommitBatchInfo {
    uint64 batchNumber;
    bytes32 newStateCommitment;
    uint256 numberOfLayer1Txs;
    uint256 numberOfLayer2Txs;
    bytes32 priorityOperationsHash;
    bytes32 dependencyRootsRollingHash;
    bytes32 l2LogsTreeRoot;
    L2DACommitmentScheme daCommitmentScheme;
    bytes32 daCommitment;
    uint64 firstBlockTimestamp;
    uint64 firstBlockNumber;
    uint64 lastBlockTimestamp;
    uint64 lastBlockNumber;
    uint256 chainId;
    bytes operatorDAInput;
    uint256 slChainId;
}

// DA, verifier registration and message-root aggregation are isolated by ExecutorTest's mocks.
// Batch counters, stored hashes, facet installation and upgrade execution use real contract calls.
// Historical bytecode provenance and the transition are described in {protocol-docs/chain-config.md}.
contract UpgradeTestV34 is ExecutorTest {
    bytes internal encodedV34Cut;
    bytes32 internal upgradeTxHash;
    address internal legacyCommitter;
    address internal legacyExecutor;
    uint256 internal previousVersion;
    uint256 internal nextVersion;

    function setUp() public {
        previousVersion = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION - 1, 0);
        nextVersion = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION, 0);
        address ctm = getters.getChainTypeManager();
        address verifier = address(getters.getVerifier());
        vm.mockCall(
            ctm,
            abi.encodeCall(IChainTypeManager.protocolVersionVerifier, (previousVersion)),
            abi.encode(verifier)
        );
        vm.mockCall(
            ctm,
            abi.encodeCall(IChainTypeManager.protocolVersionVerifier, (nextVersion)),
            abi.encode(verifier)
        );
        vm.mockCall(ctm, abi.encodeCall(IChainTypeManager.protocolVersion, ()), abi.encode(previousVersion));

        CTMUpgradeHarness script = new CTMUpgradeHarness();
        script.setReplacementFacets(getters.facets());
        StateTransitionDeployedAddresses memory stateTransition;
        stateTransition.defaultUpgrade = script.deployDefaultUpgrade(ctm);

        string memory fixture = vm.readFile(LEGACY_V33_COMMITMENT_FACETS_PATH);
        legacyCommitter = _deployHistoricalFacet(
            bytes.concat(vm.parseJsonBytes(fixture, ".committerCreationCode"), abi.encode(block.chainid))
        );
        legacyExecutor = _deployHistoricalFacet(vm.parseJsonBytes(fixture, ".executorCreationCode"));
        Diamond.FacetCut[] memory legacyCuts = new Diamond.FacetCut[](2);
        bytes4[] memory commitSelectors = new bytes4[](1);
        commitSelectors[0] = ICommitter.commitBatchesSharedBridge.selector;
        legacyCuts[0] = Diamond.FacetCut(legacyCommitter, Diamond.Action.Replace, true, commitSelectors);
        bytes4[] memory executorSelectors = new bytes4[](3);
        executorSelectors[0] = IExecutor.proveBatchesSharedBridge.selector;
        executorSelectors[1] = IExecutor.executeBatchesSharedBridge.selector;
        executorSelectors[2] = IExecutor.revertBatchesSharedBridge.selector;
        legacyCuts[1] = Diamond.FacetCut(legacyExecutor, Diamond.Action.Replace, true, executorSelectors);
        Diamond.DiamondCutData memory legacyCut = Diamond.DiamondCutData({
            facetCuts: legacyCuts,
            initAddress: address(new DefaultUpgrade()),
            initCalldata: abi.encodeCall(
                DefaultUpgrade.upgrade,
                (ProposedUpgradeLib.emptyProposedUpgrade(previousVersion))
            )
        });
        vm.prank(ctm);
        admin.executeUpgrade(legacyCut);
        assertEq(getters.getProtocolVersion(), previousVersion);

        ChainCreationParamsConfig memory creationParams;
        creationParams.latestProtocolVersion = nextVersion;
        PublishFactoryDepsResult memory factoryDeps;
        encodedV34Cut = abi.encode(
            script.generateUpgradeCutData(stateTransition, creationParams, factoryDeps, address(getters))
        );
        ProposedUpgrade memory proposal = script.getProposedUpgrade(
            creationParams,
            factoryDeps,
            UpgradeHelperLib.getProtocolUpgradeNonce(nextVersion)
        );
        // The diamond records the tx after the inherited per-chain rewrite of the placeholder payload.
        Diamond.DiamondCutData memory v34Cut = abi.decode(encodedV34Cut, (Diamond.DiamondCutData));
        proposal.l2ProtocolUpgradeTx.data = DefaultUpgradeZKsyncOS(v34Cut.initAddress).getL2UpgradeTxData(
            address(dummyBridgehub),
            l2ChainId,
            proposal.l2ProtocolUpgradeTx.data
        );
        upgradeTxHash = keccak256(abi.encode(proposal.l2ProtocolUpgradeTx));
        vm.mockCall(
            ctm,
            abi.encodeCall(IChainTypeManager.upgradeCutHash, (previousVersion)),
            abi.encode(keccak256(encodedV34Cut))
        );
        newCommitBatchInfoZKsyncOS.dependencyRootsRollingHash = bytes32(0);
    }

    function test_LegacyBatchExecutedBeforeV34Cut() public {
        Diamond.DiamondCutData memory v34Cut = abi.decode(encodedV34Cut, (Diamond.DiamondCutData));
        IExecutor.StoredBatchInfo memory legacyBatch = _commitAndProveLegacyBatch();
        _executeBatch(legacyBatch);
        assertEq(getters.getTotalBatchesExecuted(), legacyBatch.batchNumber);

        _mockCTMProtocolVersion(nextVersion);
        vm.expectEmit(address(admin));
        emit BaseZkSyncUpgrade.NewProtocolVersion(previousVersion, nextVersion);
        vm.expectEmit(address(admin));
        emit IAdmin.ExecuteUpgrade(v34Cut);
        vm.prank(owner);
        admin.upgradeChainFromVersion(address(0), previousVersion, v34Cut);
        assertEq(getters.getProtocolVersion(), nextVersion);
        assertNotEq(getters.facetAddress(ICommitter.commitBatchesSharedBridge.selector), legacyCommitter);
        assertNotEq(getters.facetAddress(IExecutor.proveBatchesSharedBridge.selector), legacyExecutor);
        assertEq(getters.getL2SystemContractsUpgradeTxHash(), upgradeTxHash);

        CommitBatchInfoZKsyncOS memory nextBatch = newCommitBatchInfoZKsyncOS;
        nextBatch.batchNumber = legacyBatch.batchNumber + 1;
        nextBatch.firstBlockNumber = newCommitBatchInfoZKsyncOS.lastBlockNumber + 1;
        nextBatch.lastBlockNumber = nextBatch.firstBlockNumber + 1;
        nextBatch.newStateCommitment = keccak256("v34 state");
        IExecutor.StoredBatchInfo memory stored = _commitOSBatchGetStored(legacyBatch, nextBatch);
        assertEq(
            stored.commitment,
            keccak256(
                abi.encodePacked(
                    legacyBatch.batchHash,
                    nextBatch.newStateCommitment,
                    nextBatch.chainConfigHash,
                    _batchOutputHash(nextBatch, upgradeTxHash)
                )
            )
        );
        _proveBatch(legacyBatch, stored, uint256(stored.commitment));
        assertEq(getters.getL2SystemContractsUpgradeBatchNumber(), stored.batchNumber);

        _executeBatch(stored);
        assertEq(getters.getTotalBatchesCommitted(), stored.batchNumber);
        assertEq(getters.getTotalBatchesVerified(), stored.batchNumber);
        assertEq(getters.getTotalBatchesExecuted(), stored.batchNumber);
        assertEq(getters.getL2SystemContractsUpgradeTxHash(), bytes32(0));
        assertEq(getters.getL2SystemContractsUpgradeBatchNumber(), 0);
    }

    function test_UnverifiedLegacyBatchRevertsTheEntireV34Cut() public {
        IExecutor.StoredBatchInfo memory legacyBatch = _commitLegacyBatch();
        _assertV34CutRejected(legacyBatch, 0);
    }

    // The v34 cut uses the default all-executed boundary, so a proved legacy batch must also be executed first.
    function test_UnexecutedLegacyBatchRevertsTheEntireV34Cut() public {
        IExecutor.StoredBatchInfo memory legacyBatch = _commitAndProveLegacyBatch();
        _assertV34CutRejected(legacyBatch, 1);
    }

    function _assertV34CutRejected(IExecutor.StoredBatchInfo memory _legacyBatch, uint256 _verified) internal {
        Diamond.DiamondCutData memory v34Cut = abi.decode(encodedV34Cut, (Diamond.DiamondCutData));
        bytes32 facetsBefore = keccak256(abi.encode(getters.facets()));
        address verifierBefore = address(getters.getVerifier());
        _mockCTMProtocolVersion(nextVersion);
        vm.recordLogs();
        vm.expectRevert(NotAllBatchesExecuted.selector);
        vm.prank(owner);
        admin.upgradeChainFromVersion(address(0), previousVersion, v34Cut);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(keccak256(abi.encode(getters.facets())), facetsBefore);
        assertEq(getters.getProtocolVersion(), previousVersion);
        assertEq(address(getters.getVerifier()), verifierBefore);
        assertEq(getters.storedBatchHash(_legacyBatch.batchNumber), keccak256(abi.encode(_legacyBatch)));
        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(getters.getTotalBatchesVerified(), _verified);
        assertEq(getters.getTotalBatchesExecuted(), 0);
        assertEq(getters.getL2SystemContractsUpgradeTxHash(), bytes32(0));
    }

    function _commitAndProveLegacyBatch() internal returns (IExecutor.StoredBatchInfo memory legacyBatch) {
        legacyBatch = _commitLegacyBatch();
        // The frozen v33 executor uses the four-word config preceding L1 transaction filtering.
        bytes32 legacyConfigHash = keccak256(
            abi.encode(
                l2ChainId,
                ZKSYNC_OS_FRI_PROOF_VERIFICATION_DISABLED,
                uint256(ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT),
                uint256(PubdataContent.FULL_PUBDATA)
            )
        );
        uint256 legacyPublicInput = uint256(
            keccak256(
                abi.encodePacked(
                    genesisStoredBatchInfo.batchHash,
                    legacyBatch.batchHash,
                    legacyConfigHash,
                    legacyBatch.commitment
                )
            )
        );
        _proveBatch(genesisStoredBatchInfo, legacyBatch, legacyPublicInput);
        assertEq(getters.getTotalBatchesExecuted(), 0);
    }

    function _executeBatch(IExecutor.StoredBatchInfo memory _batch) internal {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _batch;
        (uint256 from, uint256 to, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            batches,
            Utils.generatePriorityOps(batches.length, 0)
        );
        vm.mockCall(
            address(messageRoot),
            abi.encodeWithSelector(IMessageRootBase.addChainBatchRootV32.selector),
            bytes("")
        );
        vm.expectEmit(address(executor));
        emit IExecutor.BlockExecution(_batch.batchNumber, _batch.batchHash, _batch.commitment);
        vm.prank(validator);
        executor.executeBatchesSharedBridge(address(0), from, to, executeData);
    }

    function _mockCTMProtocolVersion(uint256 _version) internal {
        vm.mockCall(
            getters.getChainTypeManager(),
            abi.encodeCall(IChainTypeManager.protocolVersion, ()),
            abi.encode(_version)
        );
    }

    function _commitLegacyBatch() internal returns (IExecutor.StoredBatchInfo memory stored) {
        CommitBatchInfoZKsyncOS memory info = newCommitBatchInfoZKsyncOS;
        LegacyV33CommitBatchInfo[] memory batches = new LegacyV33CommitBatchInfo[](1);
        batches[0] = LegacyV33CommitBatchInfo({
            batchNumber: info.batchNumber,
            newStateCommitment: info.newStateCommitment,
            numberOfLayer1Txs: info.numberOfLayer1Txs,
            numberOfLayer2Txs: info.numberOfLayer2Txs,
            priorityOperationsHash: info.priorityOperationsHash,
            dependencyRootsRollingHash: info.dependencyRootsRollingHash,
            l2LogsTreeRoot: info.l2LogsTreeRoot,
            daCommitmentScheme: info.daCommitmentScheme,
            daCommitment: info.daCommitment,
            firstBlockTimestamp: info.firstBlockTimestamp,
            firstBlockNumber: info.firstBlockNumber,
            lastBlockTimestamp: info.lastBlockTimestamp,
            lastBlockNumber: info.lastBlockNumber,
            chainId: info.chainId,
            operatorDAInput: info.operatorDAInput,
            slChainId: info.slChainId
        });
        stored = IExecutor.StoredBatchInfo({
            batchNumber: info.batchNumber,
            batchHash: info.newStateCommitment,
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: info.numberOfLayer1Txs,
            priorityOperationsHash: info.priorityOperationsHash,
            l2LogsTreeRoot: info.l2LogsTreeRoot,
            dependencyRootsRollingHash: info.dependencyRootsRollingHash,
            timestamp: 0,
            commitment: _batchOutputHash(info, bytes32(0))
        });
        _mockDAForCommit(info.batchNumber);
        vm.expectEmit(address(committer));
        emit ICommitter.BlockCommit(info.batchNumber, stored.batchHash, stored.commitment);
        vm.prank(validator);
        committer.commitBatchesSharedBridge(
            address(0),
            info.batchNumber,
            info.batchNumber,
            abi.encodePacked(LEGACY_V33_COMMIT_ENCODING_VERSION, abi.encode(genesisStoredBatchInfo, batches))
        );
        assertEq(getters.storedBatchHash(info.batchNumber), keccak256(abi.encode(stored)));
        assertEq(getters.getTotalBatchesCommitted(), info.batchNumber);
    }

    function _proveBatch(
        IExecutor.StoredBatchInfo memory _previous,
        IExecutor.StoredBatchInfo memory _batch,
        uint256 _publicInput
    ) internal {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _batch;
        uint256[] memory publicInputs = new uint256[](1);
        publicInputs[0] = _publicInput;
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeProveBatchesData(_previous, batches, proofInput);
        vm.expectCall(address(getters.getVerifier()), abi.encodeCall(IVerifier.verify, (publicInputs, proofInput)));
        vm.expectEmit(address(executor));
        emit IExecutor.BlocksVerification(_previous.batchNumber, _batch.batchNumber);
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, data);
        assertEq(getters.getTotalBatchesVerified(), _batch.batchNumber);
    }

    function _deployHistoricalFacet(bytes memory _creationCode) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(_creationCode, 0x20), mload(_creationCode))
        }
        require(deployed != address(0), "Historical facet deployment failed");
    }

    function _batchOutputHash(
        CommitBatchInfoZKsyncOS memory _batch,
        bytes32 _upgradeTxHash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _batch.firstBlockTimestamp,
                    _batch.lastBlockTimestamp,
                    uint256(_batch.daCommitmentScheme),
                    _batch.daCommitment,
                    _batch.numberOfLayer1Txs,
                    _batch.numberOfLayer2Txs,
                    _batch.priorityOperationsHash,
                    _batch.l2LogsTreeRoot,
                    _upgradeTxHash,
                    _batch.dependencyRootsRollingHash,
                    _batch.slChainId
                )
            );
    }
}
