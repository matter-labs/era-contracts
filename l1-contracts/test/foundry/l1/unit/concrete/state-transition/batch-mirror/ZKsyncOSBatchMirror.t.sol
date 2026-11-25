// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ZKsyncOSBatchMirrorSharedTest, RejectingVerifier} from "./_ZKsyncOSBatchMirror_Shared.t.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";

import {ZKsyncOSBatchMirror} from "contracts/state-transition/batch-mirror/ZKsyncOSBatchMirror.sol";
import {
    IZKsyncOSBatchMirror,
    ZKsyncOSBatchMirrorInitParams,
    ZKsyncOSChainConfig
} from "contracts/state-transition/chain-interfaces/IZKsyncOSBatchMirror.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {ZKsyncOSBatchCommitment} from "contracts/state-transition/libraries/ZKsyncOSBatchCommitment.sol";
import {
    DisabledProofSystems,
    ProofSystem,
    PubdataContent,
    ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE,
    ZKSYNC_OS_PLONK_VERIFICATION_TYPE
} from "contracts/common/Config.sol";
import {
    BatchHashMismatch,
    CanOnlyProcessOneBatch,
    ChainConfigHashMismatch,
    EmptyData,
    IncorrectBatchBounds,
    IncorrectBatchChainId,
    InvalidMockProof,
    InvalidProof,
    InvalidProofSystem,
    Unauthorized,
    UnknownProofType,
    UnsupportedCommitBatchEncoding,
    UnsupportedProofBatchEncoding,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    BatchMirrorLengthMismatch,
    SettlementLayerChainIdMismatch
} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {OnlyChain} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

contract ZKsyncOSBatchMirrorTest is ZKsyncOSBatchMirrorSharedTest {
    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION AND REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_startsAtTheAnchor() public view {
        assertEq(mirror.getChainId(), FOLLOWED_CHAIN_ID);
        assertEq(mirror.getSettlementLayerChainId(), SETTLEMENT_LAYER_CHAIN_ID);
        assertEq(mirror.getBridgehub(), address(bridgehub));
        assertEq(mirror.getChainTypeManager(), chainTypeManager);
        assertEq(mirror.getBaseTokenAssetId(), baseTokenAssetId);
        assertEq(mirror.getAdmin(), owner);
        assertEq(mirror.getVerifier(), address(verifier));
        assertEq(mirror.getTotalBatchesExecuted(), ANCHOR_BATCH_NUMBER);
        assertEq(mirror.storedBatchHash(ANCHOR_BATCH_NUMBER), keccak256(abi.encode(anchor)));
        assertEq(mirror.l2LogsRootHash(ANCHOR_BATCH_NUMBER), anchor.l2LogsTreeRoot);
        assertEq(abi.encode(mirror.getZKsyncOSChainConfig()), abi.encode(chainConfig));
        assertEq(
            mirror.getZKsyncOSChainConfigHash(),
            ZKsyncOSBatchCommitment.chainConfigHash(
                FOLLOWED_CHAIN_ID,
                MAX_TX_GAS_LIMIT,
                PubdataContent.FULL_PUBDATA,
                false,
                true
            )
        );
        assertTrue(mirror.isValidator(validator));
        assertFalse(mirror.isValidator(owner));
    }

    function test_registration_makesTheMirrorTheFollowedChainsZKChain() public view {
        assertEq(bridgehub.getZKChain(FOLLOWED_CHAIN_ID), address(mirror));
        assertEq(bridgehub.chainTypeManager(FOLLOWED_CHAIN_ID), chainTypeManager);
        assertEq(bridgehub.baseTokenAssetId(FOLLOWED_CHAIN_ID), baseTokenAssetId);
        assertTrue(messageRoot.chainRegistered(FOLLOWED_CHAIN_ID));
        // The MessageRoot continues the chain's batch numbering from the anchor.
        assertEq(messageRoot.currentChainBatchNumber(FOLLOWED_CHAIN_ID), ANCHOR_BATCH_NUMBER);
    }

    function test_initialize_rejectsZeroAddresses() public {
        ZKsyncOSBatchMirrorInitParams memory params = _initParams();
        params.owner = address(0);
        _expectInitializeRevert(params);

        params = _initParams();
        params.bridgehub = address(0);
        _expectInitializeRevert(params);

        params = _initParams();
        params.chainTypeManager = address(0);
        _expectInitializeRevert(params);

        params = _initParams();
        params.verifier = IVerifier(address(0));
        _expectInitializeRevert(params);
    }

    function test_initialize_onlyOnce() public {
        vm.expectRevert("Initializable: contract is already initialized");
        mirror.initialize(_initParams());

        ZKsyncOSBatchMirror implementation = new ZKsyncOSBatchMirror();
        vm.expectRevert("Initializable: contract is already initialized");
        implementation.initialize(_initParams());
    }

    function _expectInitializeRevert(ZKsyncOSBatchMirrorInitParams memory _params) internal {
        // `initialize` reverts inside the proxy's constructor; the external call lets `expectRevert` see it.
        vm.expectRevert(ZeroAddress.selector);
        this.deployMirrorExternal(_params);
    }

    function deployMirrorExternal(ZKsyncOSBatchMirrorInitParams memory _params) external {
        _deployMirror(_params);
    }

    /*//////////////////////////////////////////////////////////////
                            HAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function test_mirrorBatches_singleBatch() public {
        Range memory range = _seal(1);
        IExecutor.StoredBatchInfo memory batch = range.batches[0];

        vm.expectEmit(true, true, true, true, address(mirror));
        emit IExecutor.BlockExecution(batch.batchNumber, batch.batchHash, batch.commitment);
        vm.expectEmit(true, true, true, true, address(mirror));
        emit IZKsyncOSBatchMirror.BatchesMirrored(ANCHOR_BATCH_NUMBER + 1, ANCHOR_BATCH_NUMBER + 1);
        _mirror(range);

        assertEq(mirror.getTotalBatchesExecuted(), ANCHOR_BATCH_NUMBER + 1);
        assertEq(mirror.storedBatchHash(batch.batchNumber), keccak256(abi.encode(batch)));
        assertEq(mirror.l2LogsRootHash(batch.batchNumber), batch.l2LogsTreeRoot);
        assertEq(messageRoot.chainBatchRoots(FOLLOWED_CHAIN_ID, batch.batchNumber), batch.l2LogsTreeRoot);
        assertEq(messageRoot.currentChainBatchNumber(FOLLOWED_CHAIN_ID), batch.batchNumber);
        assertEq(messageRoot.chainBatchRootTimestamp(FOLLOWED_CHAIN_ID, batch.batchNumber), block.timestamp);
    }

    function test_mirrorBatches_manyBatchesInOneProofAndAcrossProofs() public {
        Range memory first = _seal(3);
        _mirror(first);
        Range memory second = _seal(2);
        _mirror(second);

        assertEq(mirror.getTotalBatchesExecuted(), ANCHOR_BATCH_NUMBER + 5);
        _assertMirrored(first);
        _assertMirrored(second);
    }

    function testFuzz_mirrorBatches_anyRangeSize(uint8 _count) public {
        uint256 count = bound(_count, 1, 12);
        Range memory range = _seal(count);
        _mirror(range);

        assertEq(mirror.getTotalBatchesExecuted(), ANCHOR_BATCH_NUMBER + count);
        _assertMirrored(range);
    }

    /// @notice The upgrade transaction hash enters the commitment, so a batch mirrors only with the hash the
    /// settlement layer committed it with.
    function test_mirrorBatches_withUpgradeTransaction() public {
        bytes32[] memory roots = new bytes32[](2);
        roots[0] = _chainBatchRoot(keccak256("upgrade batch logs"));
        roots[1] = _chainBatchRoot(keccak256("next batch logs"));
        bytes32[] memory upgradeTxHashes = new bytes32[](2);
        upgradeTxHashes[0] = keccak256("upgrade tx");
        Range memory range = _sealWithRoots(roots, upgradeTxHashes);

        (bytes[] memory commitData, bytes memory proofData) = _encode(range);
        vm.prank(validator);
        vm.expectRevert(_hashMismatch(range, 0, bytes32(0)));
        mirror.mirrorBatches(commitData, new bytes32[](2), proofData);

        _mirror(range);
        _assertMirrored(range);
    }

    /// @notice A batch's own `chainConfigHash` is what its commitment binds; the owner follows a change of
    /// the followed chain's configuration, and from then on only batches under the new one mirror.
    function test_mirrorBatches_followsAChainConfigChange() public {
        _mirror(_seal(1));
        ZKsyncOSChainConfig memory newConfig = chainConfig;
        newConfig.l1TxFilteringEnabled = true;
        bytes32 oldHash = mirror.getZKsyncOSChainConfigHash();
        bytes32 newHash = ZKsyncOSBatchCommitment.chainConfigHash(
            FOLLOWED_CHAIN_ID,
            newConfig.maxTxGasLimit,
            newConfig.pubdataContent,
            newConfig.l1TxFilteringEnabled,
            newConfig.largeContractsEnabled
        );

        // A batch committed under the old configuration, mirrored after the change.
        Range memory stale = _seal(1);
        vm.expectEmit(true, true, true, true, address(mirror));
        emit IZKsyncOSBatchMirror.NewZKsyncOSChainConfig(oldHash, newHash);
        vm.prank(owner);
        mirror.setZKsyncOSChainConfig(newConfig);
        assertEq(mirror.getZKsyncOSChainConfigHash(), newHash);
        _expectMirrorRevert(stale, abi.encodeWithSelector(ChainConfigHashMismatch.selector, newHash, oldHash));

        // The settlement layer re-commits it under the new configuration.
        settlementLayerTip = stale.previous;
        Range memory fresh = _seal(1);
        _mirror(fresh);
        _assertMirrored(fresh);
    }

    function _assertMirrored(Range memory _range) internal view {
        for (uint256 i = 0; i < _range.batches.length; ++i) {
            IExecutor.StoredBatchInfo memory batch = _range.batches[i];
            assertEq(mirror.storedBatchHash(batch.batchNumber), keccak256(abi.encode(batch)));
            assertEq(mirror.l2LogsRootHash(batch.batchNumber), batch.l2LogsTreeRoot);
            assertEq(messageRoot.chainBatchRoots(FOLLOWED_CHAIN_ID, batch.batchNumber), batch.l2LogsTreeRoot);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            REJECTED RANGES
    //////////////////////////////////////////////////////////////*/

    function test_mirrorBatches_onlyValidators() public {
        Range memory range = _seal(1);
        (bytes[] memory commitData, bytes memory proofData) = _encode(range);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, owner));
        mirror.mirrorBatches(commitData, range.upgradeTxHashes, proofData);

        vm.prank(owner);
        mirror.setValidator(validator, false);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validator));
        mirror.mirrorBatches(commitData, range.upgradeTxHashes, proofData);
    }

    function test_mirrorBatches_rejectsAnEmptyRange() public {
        Range memory range = _seal(1);
        (, bytes memory proofData) = _encode(range);

        vm.prank(validator);
        vm.expectRevert(EmptyData.selector);
        mirror.mirrorBatches(new bytes[](0), new bytes32[](0), proofData);
    }

    function test_mirrorBatches_needsAnUpgradeTxHashPerBatch() public {
        Range memory range = _seal(2);
        range.upgradeTxHashes = new bytes32[](1);

        _expectMirrorRevert(range, abi.encodeWithSelector(BatchMirrorLengthMismatch.selector, 2, 1));
    }

    /// @notice The proof must cover exactly the batches after the newest mirrored one.
    function test_mirrorBatches_rangeMustContinueFromTheNewestMirroredBatch() public {
        _seal(1);
        // Batch 7 alone, while batch 6 was never mirrored.
        Range memory skipping = _seal(1);

        _expectMirrorRevert(
            skipping,
            abi.encodeWithSelector(
                IncorrectBatchBounds.selector,
                ANCHOR_BATCH_NUMBER + 1,
                ANCHOR_BATCH_NUMBER + 1,
                ANCHOR_BATCH_NUMBER + 2,
                ANCHOR_BATCH_NUMBER + 2
            )
        );
    }

    function test_mirrorBatches_rejectsAMirroredRangeAgain() public {
        Range memory range = _seal(1);
        _mirror(range);

        _expectMirrorRevert(
            range,
            abi.encodeWithSelector(
                IncorrectBatchBounds.selector,
                ANCHOR_BATCH_NUMBER + 2,
                ANCHOR_BATCH_NUMBER + 2,
                ANCHOR_BATCH_NUMBER + 1,
                ANCHOR_BATCH_NUMBER + 1
            )
        );
    }

    function test_mirrorBatches_proofMustStartFromTheNewestMirroredBatch() public {
        Range memory range = _seal(1);
        (bytes[] memory commitData, ) = _encode(range);
        IExecutor.StoredBatchInfo memory otherAnchor = anchor;
        otherAnchor.batchHash = keccak256("another state");
        (, , bytes memory proofData) = Utils.encodeProveBatchesData(otherAnchor, range.batches, range.proof);

        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(anchor)),
                keccak256(abi.encode(otherAnchor))
            )
        );
        mirror.mirrorBatches(commitData, range.upgradeTxHashes, proofData);
    }

    function test_mirrorBatches_proofMustHoldOneBatchPerCommit() public {
        Range memory range = _seal(1);
        (bytes[] memory commitData, ) = _encode(range);
        // A proved range [6, 6]: within the bounds, but two batches for one commit.
        IExecutor.StoredBatchInfo[] memory proved = new IExecutor.StoredBatchInfo[](2);
        proved[0] = range.batches[0];
        proved[1] = range.batches[0];
        (, , bytes memory proofData) = Utils.encodeProveBatchesData(range.previous, proved, range.proof);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(BatchMirrorLengthMismatch.selector, 1, 2));
        mirror.mirrorBatches(commitData, range.upgradeTxHashes, proofData);
    }

    function test_mirrorBatches_commitMustHoldOneBatch() public {
        Range memory range = _seal(1);
        (, bytes memory proofData) = _encode(range);
        CommitBatchInfoZKsyncOS[] memory twice = new CommitBatchInfoZKsyncOS[](2);
        twice[0] = range.commits[0];
        twice[1] = range.commits[0];
        bytes[] memory commitData = new bytes[](1);
        (, , commitData[0]) = Utils.encodeCommitBatchesDataZKsyncOS(range.previous, twice);

        vm.prank(validator);
        vm.expectRevert(CanOnlyProcessOneBatch.selector);
        mirror.mirrorBatches(commitData, range.upgradeTxHashes, proofData);
    }

    function test_mirrorBatches_commitMustContinueFromThePreviousBatch() public {
        Range memory range = _seal(2);
        (bytes[] memory commitData, bytes memory proofData) = _encode(range);
        // The second commit claims to continue from the anchor instead of from batch 6.
        CommitBatchInfoZKsyncOS[] memory single = new CommitBatchInfoZKsyncOS[](1);
        single[0] = range.commits[1];
        (, , commitData[1]) = Utils.encodeCommitBatchesDataZKsyncOS(anchor, single);

        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(range.batches[0])),
                keccak256(abi.encode(anchor))
            )
        );
        mirror.mirrorBatches(commitData, range.upgradeTxHashes, proofData);
    }

    function test_mirrorBatches_commitsMustBeInOrder() public {
        Range memory range = _seal(2);
        (bytes[] memory commitData, bytes memory proofData) = _encode(range);
        (commitData[0], commitData[1]) = (commitData[1], commitData[0]);

        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IncorrectBatchBounds.selector,
                ANCHOR_BATCH_NUMBER + 1,
                ANCHOR_BATCH_NUMBER + 1,
                ANCHOR_BATCH_NUMBER + 2,
                ANCHOR_BATCH_NUMBER + 2
            )
        );
        mirror.mirrorBatches(commitData, range.upgradeTxHashes, proofData);
    }

    function test_mirrorBatches_rejectsABatchOfAnotherChain() public {
        Range memory range = _seal(1);
        range.commits[0].chainId = FOLLOWED_CHAIN_ID + 1;

        _expectMirrorRevert(
            range,
            abi.encodeWithSelector(IncorrectBatchChainId.selector, FOLLOWED_CHAIN_ID + 1, FOLLOWED_CHAIN_ID)
        );
    }

    /// @notice A batch must name the followed chain's real settlement layer, not the mirror's host chain.
    function test_mirrorBatches_rejectsABatchSettledElsewhere() public {
        Range memory range = _seal(1);
        range.commits[0].slChainId = block.chainid;

        _expectMirrorRevert(range, abi.encodeWithSelector(SettlementLayerChainIdMismatch.selector));
    }

    function test_mirrorBatches_rejectsABatchUnderAnotherConfig() public {
        Range memory range = _seal(1);
        range.commits[0].chainConfigHash = keccak256("another config");

        _expectMirrorRevert(
            range,
            abi.encodeWithSelector(
                ChainConfigHashMismatch.selector,
                mirror.getZKsyncOSChainConfigHash(),
                keccak256("another config")
            )
        );
    }

    /// @notice The chain batch root is not a public input on its own; recomputing the commitment from the
    /// commit data is what rejects a forged one in the proved batch.
    function test_mirrorBatches_rejectsAForgedRootInTheProvedBatch() public {
        Range memory range = _seal(1);
        bytes32 honestHash = keccak256(abi.encode(range.batches[0]));
        range.batches[0].l2LogsTreeRoot = keccak256("forged root");

        _expectMirrorRevert(
            range,
            abi.encodeWithSelector(BatchHashMismatch.selector, honestHash, keccak256(abi.encode(range.batches[0])))
        );
    }

    /// @notice A consistent forgery, a forged root in both the commit and the proved batch with the
    /// commitment recomputed, changes the public input, so the proof made for the real batch fails.
    function test_mirrorBatches_rejectsAConsistentForgery() public {
        Range memory range = _seal(1);
        range.commits[0].l2LogsTreeRoot = keccak256("forged root");
        range.batches[0] = _storedBatchInfo(range.previous, range.commits[0], bytes32(0));

        _expectMirrorRevert(range, abi.encodeWithSelector(InvalidMockProof.selector));
    }

    function test_mirrorBatches_rejectsAProofOfOtherBatches() public {
        Range memory range = _seal(1);
        range.proof[3] = 12345;

        _expectMirrorRevert(range, abi.encodeWithSelector(InvalidMockProof.selector));
    }

    function test_mirrorBatches_rejectsAProofTheVerifierRejects() public {
        RejectingVerifier rejectingVerifier = new RejectingVerifier();
        vm.prank(owner);
        mirror.setVerifier(rejectingVerifier);

        _expectMirrorRevert(_seal(1), abi.encodeWithSelector(InvalidProof.selector));
    }

    function test_mirrorBatches_rejectsUnsupportedEncodings() public {
        Range memory range = _seal(1);
        (bytes[] memory commitData, bytes memory proofData) = _encode(range);

        bytes memory badProofData = bytes.concat(bytes1(0x09), _tail(proofData));
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(UnsupportedProofBatchEncoding.selector, 9));
        mirror.mirrorBatches(commitData, range.upgradeTxHashes, badProofData);

        commitData[0] = bytes.concat(bytes1(BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT - 1), _tail(commitData[0]));
        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(
                UnsupportedCommitBatchEncoding.selector,
                BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT - 1
            )
        );
        mirror.mirrorBatches(commitData, range.upgradeTxHashes, proofData);
    }

    /// @notice Until the Bridgehub owner registers it, the mirror cannot append roots, so it mirrors nothing.
    function test_mirrorBatches_needsTheMirrorRegistered() public {
        ZKsyncOSBatchMirrorInitParams memory params = _initParams();
        params.chainId = FOLLOWED_CHAIN_ID + 1;
        mirror = _deployMirror(params);
        vm.prank(owner);
        mirror.setValidator(validator, true);
        Range memory range = _seal(1);
        range.commits[0].chainId = FOLLOWED_CHAIN_ID + 1;
        range.batches[0] = _storedBatchInfo(range.previous, range.commits[0], bytes32(0));
        range.proof = _mockProof(range.batches);

        _expectMirrorRevert(range, abi.encodeWithSelector(OnlyChain.selector, address(mirror), address(0)));
        assertEq(mirror.getTotalBatchesExecuted(), ANCHOR_BATCH_NUMBER);
    }

    /// @notice A rejected range leaves nothing behind.
    function test_mirrorBatches_rejectedRangeChangesNothing() public {
        Range memory range = _seal(3);
        range.commits[2].slChainId = block.chainid;
        _expectMirrorRevert(range, abi.encodeWithSelector(SettlementLayerChainIdMismatch.selector));

        assertEq(mirror.getTotalBatchesExecuted(), ANCHOR_BATCH_NUMBER);
        assertEq(mirror.storedBatchHash(ANCHOR_BATCH_NUMBER + 1), bytes32(0));
        assertEq(messageRoot.currentChainBatchNumber(FOLLOWED_CHAIN_ID), ANCHOR_BATCH_NUMBER);
    }

    function _hashMismatch(
        Range memory _range,
        uint256 _index,
        bytes32 _upgradeTxHash
    ) internal pure returns (bytes memory) {
        IExecutor.StoredBatchInfo memory previous = _index == 0 ? _range.previous : _range.batches[_index - 1];
        IExecutor.StoredBatchInfo memory recomputed = _storedBatchInfo(
            previous,
            _range.commits[_index],
            _upgradeTxHash
        );
        return
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(recomputed)),
                keccak256(abi.encode(_range.batches[_index]))
            );
    }

    function _tail(bytes memory _data) internal pure returns (bytes memory tail) {
        tail = new bytes(_data.length - 1);
        for (uint256 i = 1; i < _data.length; ++i) {
            tail[i - 1] = _data[i];
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VERIFIER AND PROOF SYSTEMS
    //////////////////////////////////////////////////////////////*/

    /// @notice `MultiProofVerifier` reads the proof systems the calling chain requires from its caller, here
    /// the mirror. While ZiSK is required, a lone Airbender (PLONK) proof is rejected; after the owner follows
    /// the followed chain's switch, the same proof is accepted.
    function test_verifier_readsTheMirrorsDisabledProofSystems() public {
        Range memory range = _seal(1);
        range.proof = new uint256[](2);
        range.proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE;
        range.proof[1] = 0;
        assertEq(mirror.getProofMode(), ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE);
        _expectMirrorRevert(
            range,
            abi.encodeWithSelector(UnknownProofType.selector, ZKSYNC_OS_PLONK_VERIFICATION_TYPE)
        );

        vm.prank(owner);
        mirror.setProofSystemStatus(ProofSystem.Zisk, false);
        assertEq(mirror.getProofMode(), ZKSYNC_OS_PLONK_VERIFICATION_TYPE);
        _mirror(range);
        _assertMirrored(range);
    }

    function test_setProofSystemStatus_followsTheZiskSwitch() public {
        vm.expectEmit(true, true, true, true, address(mirror));
        emit IAdmin.NewDisabledProofSystems(0, uint8(1 << uint8(ProofSystem.Zisk)));
        vm.prank(owner);
        mirror.setProofSystemStatus(ProofSystem.Zisk, false);
        DisabledProofSystems memory disabled = mirror.disabledProofSystems();
        assertTrue(disabled.zisk);
        assertFalse(disabled.airbender);
        assertFalse(disabled.boojum);

        vm.prank(owner);
        mirror.setProofSystemStatus(ProofSystem.Zisk, true);
        assertFalse(mirror.disabledProofSystems().zisk);
    }

    function test_setProofSystemStatus_onlyZisk() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidProofSystem.selector, uint8(ProofSystem.Airbender)));
        mirror.setProofSystemStatus(ProofSystem.Airbender, false);
    }

    function test_setVerifier_replacesTheVerifier() public {
        RejectingVerifier newVerifier = new RejectingVerifier();
        vm.expectEmit(true, true, true, true, address(mirror));
        emit IZKsyncOSBatchMirror.NewVerifier(address(verifier), address(newVerifier));
        vm.prank(owner);
        mirror.setVerifier(newVerifier);
        assertEq(mirror.getVerifier(), address(newVerifier));

        vm.prank(owner);
        vm.expectRevert(ZeroAddress.selector);
        mirror.setVerifier(IVerifier(address(0)));
    }

    /*//////////////////////////////////////////////////////////////
                                OWNER
    //////////////////////////////////////////////////////////////*/

    function test_setValidator_updatesTheValidators() public {
        address other = makeAddr("otherRelayer");
        vm.expectEmit(true, true, true, true, address(mirror));
        emit IAdmin.ValidatorStatusUpdate(other, true);
        vm.prank(owner);
        mirror.setValidator(other, true);
        assertTrue(mirror.isValidator(other));

        vm.prank(owner);
        mirror.setValidator(other, false);
        assertFalse(mirror.isValidator(other));
    }

    function test_ownerFunctions_onlyOwner() public {
        address stranger = makeAddr("stranger");
        RejectingVerifier rejectingVerifier = new RejectingVerifier();
        vm.startPrank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        mirror.setValidator(stranger, true);
        vm.expectRevert("Ownable: caller is not the owner");
        mirror.setVerifier(rejectingVerifier);
        vm.expectRevert("Ownable: caller is not the owner");
        mirror.setZKsyncOSChainConfig(chainConfig);
        vm.expectRevert("Ownable: caller is not the owner");
        mirror.setProofSystemStatus(ProofSystem.Zisk, false);
        vm.stopPrank();
    }

    function test_ownership_isTransferredInTwoSteps() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        mirror.transferOwnership(newOwner);
        assertEq(mirror.getAdmin(), owner);

        vm.prank(newOwner);
        mirror.acceptOwnership();
        assertEq(mirror.getAdmin(), newOwner);
    }
}
