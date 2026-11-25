// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";

import {ZKsyncOSBatchMirror} from "contracts/state-transition/batch-mirror/ZKsyncOSBatchMirror.sol";
import {
    ZKsyncOSBatchMirrorInitParams,
    ZKsyncOSChainConfig
} from "contracts/state-transition/chain-interfaces/IZKsyncOSBatchMirror.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {MultiProofTestnetVerifier} from "contracts/state-transition/verifiers/MultiProofTestnetVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";
import {AcceptingVerifier} from "contracts/dev-contracts/test/AcceptingVerifier.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {MessageRootBase} from "contracts/core/message-root/MessageRootBase.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {L2DACommitmentScheme, PubdataContent, PUBLIC_INPUT_SHIFT} from "contracts/common/Config.sol";

/// @notice A verifier that rejects every proof by returning false, as `IVerifier` allows.
contract RejectingVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return false;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return keccak256("RejectingVerifier");
    }
}

/// @notice A `ZKsyncOSBatchMirror` on its host chain: a real Bridgehub and `MessageRoot` the mirror is
/// registered in (the L1 contracts), and a simulated settlement layer of the followed chain that produces the commit and prove
/// calldata a relayer replays. The verifier is the testnet multi-proof verifier: its mock proofs check the
/// public input the mirror computes, but not a cryptographic proof, which the verifier suites cover.
contract ZKsyncOSBatchMirrorSharedTest is Test {
    /// @notice The batches of one prove call of the simulated settlement layer, and what it was given.
    struct Range {
        IExecutor.StoredBatchInfo previous;
        CommitBatchInfoZKsyncOS[] commits;
        bytes32[] upgradeTxHashes;
        IExecutor.StoredBatchInfo[] batches;
        uint256[] proof;
    }

    uint256 internal constant FOLLOWED_CHAIN_ID = 505;
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 1001;
    uint64 internal constant ANCHOR_BATCH_NUMBER = 5;
    uint64 internal constant MAX_TX_GAS_LIMIT = 1 << 25;
    /// @dev `MultiProofTestnetVerifier`'s mock proof: `[type, carried hash, magic, public input]`.
    uint256 internal constant MOCK_PROOF_TYPE = 3;
    uint256 internal constant MOCK_PROOF_MAGIC = 13;

    address internal owner = makeAddr("mirrorOwner");
    address internal validator = makeAddr("relayer");
    address internal bridgehubOwner = makeAddr("bridgehubOwner");
    address internal chainTypeManager = makeAddr("chainTypeManager");
    bytes32 internal baseTokenAssetId = keccak256("followed chain base token");

    L1Bridgehub internal bridgehub;
    MessageRootBase internal messageRoot;
    MultiProofTestnetVerifier internal verifier;
    ZKsyncOSBatchMirror internal mirror;
    ZKsyncOSChainConfig internal chainConfig;
    IExecutor.StoredBatchInfo internal anchor;

    /// @dev The newest batch the simulated settlement layer committed.
    IExecutor.StoredBatchInfo internal settlementLayerTip;

    function setUp() public virtual {
        address chainAssetHandler = _deployHostStack();
        vm.startPrank(bridgehubOwner);
        bridgehub.setAddresses(
            makeAddr("assetRouter"),
            ICTMDeploymentTracker(makeAddr("ctmDeploymentTracker")),
            IMessageRootBase(address(messageRoot)),
            chainAssetHandler,
            makeAddr("chainRegistrationSender")
        );
        bridgehub.addChainTypeManager(chainTypeManager);
        bridgehub.addTokenAssetId(baseTokenAssetId);
        vm.stopPrank();

        AcceptingVerifier acceptingVerifier = new AcceptingVerifier();
        verifier = new MultiProofTestnetVerifier(
            new MultiProofVerifier(new ZKsyncOSTestnetVerifier(acceptingVerifier), acceptingVerifier)
        );

        chainConfig = ZKsyncOSChainConfig({
            maxTxGasLimit: MAX_TX_GAS_LIMIT,
            pubdataContent: PubdataContent.FULL_PUBDATA,
            l1TxFilteringEnabled: false,
            largeContractsEnabled: true
        });
        anchor = IExecutor.StoredBatchInfo({
            batchNumber: ANCHOR_BATCH_NUMBER,
            batchHash: keccak256("anchor state"),
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: keccak256(""),
            dependencyRootsRollingHash: bytes32(0),
            l2LogsTreeRoot: keccak256("anchor root"),
            timestamp: 0,
            commitment: keccak256("anchor commitment")
        });
        settlementLayerTip = anchor;

        mirror = _deployMirror(_initParams());
        vm.prank(owner);
        mirror.setValidator(validator, true);
        vm.prank(bridgehubOwner);
        bridgehub.registerAlreadyDeployedZKChain(FOLLOWED_CHAIN_ID, address(mirror));
    }

    /// @dev Deploys the host chain's Bridgehub and `MessageRoot` and returns its chain asset handler.
    function _deployHostStack() internal virtual returns (address chainAssetHandler) {
        bridgehub = new L1Bridgehub(bridgehubOwner, 100);
        chainAssetHandler = makeAddr("chainAssetHandler");
        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(address(bridgehub), chainAssetHandler)),
                    makeAddr("messageRootProxyAdmin"),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );
    }

    function _initParams() internal view returns (ZKsyncOSBatchMirrorInitParams memory) {
        return
            ZKsyncOSBatchMirrorInitParams({
                owner: owner,
                bridgehub: address(bridgehub),
                chainId: FOLLOWED_CHAIN_ID,
                settlementLayerChainId: SETTLEMENT_LAYER_CHAIN_ID,
                chainTypeManager: chainTypeManager,
                baseTokenAssetId: baseTokenAssetId,
                verifier: verifier,
                chainConfig: chainConfig,
                anchor: anchor
            });
    }

    function _deployMirror(ZKsyncOSBatchMirrorInitParams memory _params) internal returns (ZKsyncOSBatchMirror) {
        return
            ZKsyncOSBatchMirror(
                address(
                    new TransparentUpgradeableProxy(
                        address(new ZKsyncOSBatchMirror()),
                        makeAddr("mirrorProxyAdmin"),
                        abi.encodeCall(ZKsyncOSBatchMirror.initialize, (_params))
                    )
                )
            );
    }

    /// @dev The chain batch root of a batch whose L2->L1 logs tree root is `_logsRoot`, with an untouched
    /// interop commitment tree.
    function _chainBatchRoot(bytes32 _logsRoot) internal pure returns (bytes32) {
        return
            ChainBatchRootTree.compute(
                _logsRoot,
                bytes32(0),
                ChainBatchRootTree.EMPTY_IMT_ROOT,
                ChainBatchRootTree.EMPTY_IMT_ROOT
            );
    }

    /// @dev Commits and proves `_count` batches on the simulated settlement layer.
    function _seal(uint256 _count) internal returns (Range memory) {
        bytes32[] memory roots = new bytes32[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            roots[i] = _chainBatchRoot(keccak256(abi.encode("logs", settlementLayerTip.batchNumber + 1 + i)));
        }
        return _sealWithRoots(roots, new bytes32[](_count));
    }

    /// @dev Commits and proves one batch per root, with the given upgrade transaction hashes, as the
    /// followed chain's settlement layer would. The settlement layer and the mirror share the commitment
    /// library, which `BatchMirrorReplayTest` checks against a real `CommitterFacet`.
    function _sealWithRoots(
        bytes32[] memory _roots,
        bytes32[] memory _upgradeTxHashes
    ) internal returns (Range memory range) {
        uint256 count = _roots.length;
        range.previous = settlementLayerTip;
        range.commits = new CommitBatchInfoZKsyncOS[](count);
        range.batches = new IExecutor.StoredBatchInfo[](count);
        range.upgradeTxHashes = _upgradeTxHashes;
        IExecutor.StoredBatchInfo memory previous = settlementLayerTip;
        for (uint256 i = 0; i < count; ++i) {
            range.commits[i] = _commitInfo(previous.batchNumber + 1, _roots[i]);
            range.batches[i] = _storedBatchInfo(previous, range.commits[i], _upgradeTxHashes[i]);
            previous = range.batches[i];
        }
        range.proof = _mockProof(range.batches);
        settlementLayerTip = previous;
    }

    function _commitInfo(uint64 _batchNumber, bytes32 _root) internal view returns (CommitBatchInfoZKsyncOS memory c) {
        c.batchNumber = _batchNumber;
        c.newStateCommitment = keccak256(abi.encode("state", _batchNumber));
        c.numberOfLayer1Txs = 0;
        c.numberOfLayer2Txs = 1;
        c.priorityOperationsHash = keccak256("");
        c.dependencyRootsRollingHash = bytes32(0);
        c.l2LogsTreeRoot = _root;
        c.daCommitmentScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;
        c.daCommitment = keccak256(abi.encode("da", _batchNumber));
        c.firstBlockTimestamp = uint64(1_000 + _batchNumber * 10);
        c.firstBlockNumber = uint64(_batchNumber * 100);
        c.lastBlockTimestamp = uint64(1_005 + _batchNumber * 10);
        c.lastBlockNumber = uint64(_batchNumber * 100 + 99);
        c.chainId = FOLLOWED_CHAIN_ID;
        c.operatorDAInput = hex"00";
        c.slChainId = SETTLEMENT_LAYER_CHAIN_ID;
        c.chainConfigHash = mirror.getZKsyncOSChainConfigHash();
        c.interopFeeUnits = 0;
    }

    /// @dev The `StoredBatchInfo` the settlement layer stores for a committed batch, spelled out
    /// independently of the library the mirror uses.
    function _storedBatchInfo(
        IExecutor.StoredBatchInfo memory _previous,
        CommitBatchInfoZKsyncOS memory _commit,
        bytes32 _upgradeTxHash
    ) internal pure returns (IExecutor.StoredBatchInfo memory) {
        bytes32 outputHash = keccak256(
            abi.encodePacked(
                _commit.firstBlockTimestamp,
                _commit.lastBlockTimestamp,
                uint256(_commit.daCommitmentScheme),
                _commit.daCommitment,
                _commit.numberOfLayer1Txs,
                _commit.numberOfLayer2Txs,
                _commit.priorityOperationsHash,
                _commit.l2LogsTreeRoot,
                _upgradeTxHash,
                _commit.dependencyRootsRollingHash,
                _commit.slChainId,
                _commit.interopFeeUnits
            )
        );
        return
            IExecutor.StoredBatchInfo({
                batchNumber: _commit.batchNumber,
                batchHash: _commit.newStateCommitment,
                indexRepeatedStorageChanges: 0,
                numberOfLayer1Txs: _commit.numberOfLayer1Txs,
                priorityOperationsHash: _commit.priorityOperationsHash,
                dependencyRootsRollingHash: _commit.dependencyRootsRollingHash,
                l2LogsTreeRoot: _commit.l2LogsTreeRoot,
                timestamp: 0,
                commitment: keccak256(
                    abi.encodePacked(
                        _previous.batchHash,
                        _commit.newStateCommitment,
                        _commit.chainConfigHash,
                        outputHash
                    )
                )
            });
    }

    /// @dev A mock proof of `_batches` that `MultiProofTestnetVerifier` accepts: it carries the public
    /// input the settlement layer's verifier folds from the batch commitments.
    function _mockProof(IExecutor.StoredBatchInfo[] memory _batches) internal pure returns (uint256[] memory proof) {
        uint256[] memory publicInputs = new uint256[](_batches.length);
        for (uint256 i = 0; i < _batches.length; ++i) {
            publicInputs[i] = uint256(_batches[i].commitment);
        }
        uint256 publicInput = publicInputs.length == 1
            ? publicInputs[0]
            : uint256(keccak256(abi.encodePacked(publicInputs)));
        proof = new uint256[](4);
        proof[0] = MOCK_PROOF_TYPE;
        proof[1] = 0;
        proof[2] = MOCK_PROOF_MAGIC;
        proof[3] = publicInput >> PUBLIC_INPUT_SHIFT;
    }

    /// @dev The settlement layer calldata of a range: one commit per batch and one prove call.
    function _encode(Range memory _range) internal pure returns (bytes[] memory commitData, bytes memory proofData) {
        uint256 count = _range.commits.length;
        commitData = new bytes[](count);
        IExecutor.StoredBatchInfo memory previous = _range.previous;
        for (uint256 i = 0; i < count; ++i) {
            CommitBatchInfoZKsyncOS[] memory single = new CommitBatchInfoZKsyncOS[](1);
            single[0] = _range.commits[i];
            (, , commitData[i]) = Utils.encodeCommitBatchesDataZKsyncOS(previous, single);
            previous = i < _range.batches.length ? _range.batches[i] : previous;
        }
        (, , proofData) = Utils.encodeProveBatchesData(_range.previous, _range.batches, _range.proof);
    }

    function _mirror(Range memory _range) internal {
        (bytes[] memory commitData, bytes memory proofData) = _encode(_range);
        vm.prank(validator);
        mirror.mirrorBatches(commitData, _range.upgradeTxHashes, proofData);
    }

    function _expectMirrorRevert(Range memory _range, bytes memory _error) internal {
        (bytes[] memory commitData, bytes memory proofData) = _encode(_range);
        vm.prank(validator);
        vm.expectRevert(_error);
        mirror.mirrorBatches(commitData, _range.upgradeTxHashes, proofData);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
