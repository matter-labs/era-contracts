// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {CommitterFacet} from "contracts/state-transition/chain-deps/facets/Committer.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {InitializeData} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ICommitter, CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IZiskSnarkPlonkVerifier} from "contracts/state-transition/chain-interfaces/IZiskSnarkPlonkVerifier.sol";
import {MultiProofTestnetVerifier} from "contracts/state-transition/verifiers/MultiProofTestnetVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {ZiskVerifier} from "contracts/state-transition/verifiers/ZiskVerifier.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {
    TESTNET_COMMIT_TIMESTAMP_NOT_OLDER,
    ZISK_SNARK_PROOF_LENGTH,
    ZISK_PROOF_SYSTEM_DISABLED,
    ZKSYNC_OS_PROOF_METADATA_LENGTH,
    ZKSYNC_OS_PLONK_VERIFICATION_TYPE,
    L2DACommitmentScheme
} from "contracts/common/Config.sol";
import {InvalidDisabledProofSystemsMask, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {NotZKsyncOS} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice Exercises the per-chain switch through production facets and verifier wrappers.
/// @dev Only the SNARK backends and unrelated initialization dependencies are mocked.
contract DisabledProofSystemsTest is UtilsCallMockerTest {
    address internal chain;
    address internal owner;
    address internal validator;
    address internal airbenderPlonk;
    address internal ziskPlonk;
    MultiProofVerifier internal verifier;
    IExecutor.StoredBatchInfo internal genesis;

    function setUp() public {
        owner = makeAddr("chainAdmin");
        validator = makeAddr("validator");
        airbenderPlonk = makeAddr("airbenderPlonk");
        ziskPlonk = makeAddr("ziskPlonk");
        _setProofResults(true, true);
        verifier = new MultiProofVerifier(
            new ZKsyncOSVerifier(IVerifier(airbenderPlonk)),
            new ZiskVerifier(IZiskSnarkPlonkVerifier(ziskPlonk))
        );
        vm.warp(TESTNET_COMMIT_TIMESTAMP_NOT_OLDER + 1);
        chain = _deployChain(true, 10);
    }

    function test_default_requiresBothProofs() public {
        assertEq(IGetters(chain).disabledProofSystems(), 0);
        assertEq(IGetters(chain).getProofMode(), 5);
        IExecutor.StoredBatchInfo memory batch = _commit(chain, genesis);
        _prove(chain, genesis, batch);
        assertEq(IGetters(chain).getTotalBatchesVerified(), 1);
    }

    function test_nonAdmin_cannotDisable() public {
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validator));
        IAdmin(chain).setDisabledProofSystems(ZISK_PROOF_SYSTEM_DISABLED);
        assertEq(IGetters(chain).disabledProofSystems(), 0);
    }

    function test_eraChain_cannotDisable() public {
        address eraChain = _deployChain(false, 11);
        vm.prank(owner);
        vm.expectRevert(NotZKsyncOS.selector);
        IAdmin(eraChain).setDisabledProofSystems(ZISK_PROOF_SYSTEM_DISABLED);
        assertEq(IGetters(eraChain).disabledProofSystems(), 0);
    }

    function testFuzz_invalidMask_preservesState(uint8 _mask, bool _initiallyDisabled) public {
        vm.assume(_mask != 0 && _mask != ZISK_PROOF_SYSTEM_DISABLED);
        uint8 initialMask = _initiallyDisabled ? ZISK_PROOF_SYSTEM_DISABLED : 0;
        _setMask(chain, initialMask);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidDisabledProofSystemsMask.selector, _mask));
        IAdmin(chain).setDisabledProofSystems(_mask);
        assertEq(IGetters(chain).disabledProofSystems(), initialMask);
    }

    function test_pendingBatches_disableAndReenable() public {
        IExecutor.StoredBatchInfo memory first = _commit(chain, genesis);
        _setProofResults(true, false);
        _expectZiskFailure(chain, genesis, first);

        _setMask(chain, ZISK_PROOF_SYSTEM_DISABLED);
        assertEq(IGetters(chain).getProofMode(), 2);
        _expectWrongProofType(chain, genesis, first, 5);
        assertEq(IGetters(chain).getTotalBatchesCommitted(), 1);
        assertEq(IGetters(chain).getTotalBatchesVerified(), 0);
        // The disabled backend must not even be called, including when it reverts.
        vm.mockCallRevert(ziskPlonk, abi.encodeWithSelector(IZiskSnarkPlonkVerifier.verifyProof.selector), hex"dead");
        _prove(chain, genesis, first);

        IExecutor.StoredBatchInfo memory second = _commit(chain, first);
        _setMask(chain, 0);
        assertEq(IGetters(chain).getProofMode(), 5);
        _expectWrongProofType(chain, first, second, 2);
        _setProofResults(true, false);
        _expectZiskFailure(chain, first, second);
        assertEq(IGetters(chain).getTotalBatchesVerified(), 1);
        _setProofResults(true, true);
        _prove(chain, first, second);
        assertEq(IGetters(chain).getTotalBatchesCommitted(), 2);
        assertEq(IGetters(chain).getTotalBatchesVerified(), 2);
    }

    function test_disabled_stillRequiresAirbender() public {
        IExecutor.StoredBatchInfo memory batch = _commit(chain, genesis);
        _setMask(chain, ZISK_PROOF_SYSTEM_DISABLED);
        _setProofResults(false, true);
        bytes memory data = _proofData(genesis, batch, IGetters(chain).getProofMode());
        vm.prank(validator);
        vm.expectRevert(MultiProofVerifier.AirbenderVerificationFailed.selector);
        IExecutor(chain).proveBatchesSharedBridge(chain, batch.batchNumber, batch.batchNumber, data);
        assertEq(IGetters(chain).getTotalBatchesVerified(), 0);
    }

    function test_sharedVerifier_switchIsChainLocal() public {
        address secondChain = _deployChain(true, 11);
        assertEq(address(IGetters(chain).getVerifier()), address(verifier));
        assertEq(address(IGetters(secondChain).getVerifier()), address(verifier));
        IExecutor.StoredBatchInfo memory first = _commit(chain, genesis);
        IExecutor.StoredBatchInfo memory second = _commit(secondChain, genesis);
        _setMask(chain, ZISK_PROOF_SYSTEM_DISABLED);
        _setProofResults(true, false);
        _prove(chain, genesis, first);
        _expectZiskFailure(secondChain, genesis, second);
        assertEq(IGetters(secondChain).disabledProofSystems(), 0);
        assertEq(IGetters(secondChain).getTotalBatchesVerified(), 0);
    }

    function test_disabled_rejectsValidMultiproof() public {
        IExecutor.StoredBatchInfo memory batch = _commit(chain, genesis);
        _setMask(chain, ZISK_PROOF_SYSTEM_DISABLED);
        _expectWrongProofType(chain, genesis, batch, 5);
        _prove(chain, genesis, batch);
    }

    function test_getProofMode_distinguishesDeploymentsWithZeroMask() public {
        address singleChain = _deployChain(true, 11, address(new ZKsyncOSVerifier(IVerifier(airbenderPlonk))));
        assertEq(IGetters(chain).disabledProofSystems(), 0);
        assertEq(IGetters(singleChain).disabledProofSystems(), 0);
        assertEq(IGetters(chain).getProofMode(), 5);
        assertEq(IGetters(singleChain).getProofMode(), 2);
        IExecutor.StoredBatchInfo memory batch = _commit(singleChain, genesis);
        _prove(singleChain, genesis, batch);
    }

    function test_getProofMode_rejectsEraChain() public {
        address eraChain = _deployChain(false, 11);
        vm.expectRevert(NotZKsyncOS.selector);
        IGetters(eraChain).getProofMode();
    }

    function test_testnet_realProofs_followDiamondModeAndRemainChainLocal() public {
        MultiProofTestnetVerifier wrapper = new MultiProofTestnetVerifier(verifier);
        address firstChain = _deployChain(true, 11, address(wrapper));
        address secondChain = _deployChain(true, 12, address(wrapper));
        assertEq(IGetters(firstChain).getProofMode(), 5);
        IExecutor.StoredBatchInfo memory first = _commit(firstChain, genesis);
        IExecutor.StoredBatchInfo memory second = _commit(secondChain, genesis);
        _setMask(firstChain, ZISK_PROOF_SYSTEM_DISABLED);
        assertEq(IGetters(firstChain).getProofMode(), 2);
        assertEq(IGetters(secondChain).getProofMode(), 5);
        _expectWrongProofType(firstChain, genesis, first, 5);
        _expectWrongProofType(secondChain, genesis, second, 2);
        _prove(firstChain, genesis, first);
        _prove(secondChain, genesis, second);
    }

    function _expectWrongProofType(
        address _chain,
        IExecutor.StoredBatchInfo memory _previous,
        IExecutor.StoredBatchInfo memory _batch,
        uint256 _type
    ) internal {
        bytes memory data = _proofData(_previous, _batch, _type);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(MultiProofVerifier.UnknownProofType.selector, _type));
        IExecutor(_chain).proveBatchesSharedBridge(_chain, _batch.batchNumber, _batch.batchNumber, data);
        assertEq(IGetters(_chain).getTotalBatchesVerified(), _previous.batchNumber);
    }

    function _setProofResults(bool _airbender, bool _zisk) internal {
        vm.mockCall(airbenderPlonk, abi.encodeWithSelector(IVerifier.verify.selector), abi.encode(_airbender));
        vm.mockCall(ziskPlonk, abi.encodeWithSelector(IZiskSnarkPlonkVerifier.verifyProof.selector), abi.encode(_zisk));
    }

    function _setMask(address _chain, uint8 _mask) internal {
        uint8 oldMask = IGetters(_chain).disabledProofSystems();
        vm.expectEmit(true, true, false, true, _chain);
        emit IAdmin.NewDisabledProofSystems(oldMask, _mask);
        vm.prank(owner);
        IAdmin(_chain).setDisabledProofSystems(_mask);
        assertEq(IGetters(_chain).disabledProofSystems(), _mask);
    }

    function _deployChain(bool _isZKsyncOS, uint256 _chainId) internal returns (address) {
        return _deployChain(_isZKsyncOS, _chainId, address(verifier));
    }

    function _deployChain(bool _isZKsyncOS, uint256 _chainId, address _verifier) internal returns (address result) {
        address bridgehub = makeAddr("bridgehub");
        InitializeData memory init = Utils.makeInitializeData(bridgehub);
        init.chainId = _chainId;
        init.admin = owner;
        init.validatorTimelock = validator;
        init.storedBatchZero = keccak256(abi.encode(genesis));
        mockDiamondInitInteropCenterCallsWithAddress(bridgehub, address(0), init.baseTokenAssetId);
        mockChainTypeManagerVerifier(_verifier);
        vm.mockCall(
            init.chainTypeManager,
            abi.encodeCall(IChainTypeManager.protocolVersionIsActive, (init.protocolVersion)),
            abi.encode(true)
        );

        Diamond.FacetCut[] memory cuts = new Diamond.FacetCut[](4);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IAdmin.setDisabledProofSystems.selector;
        selectors[1] = IAdmin.setDAValidatorPair.selector;
        cuts[0] = _cut(address(new AdminFacet(block.chainid, RollupDAManager(address(0)))), selectors);
        selectors = new bytes4[](1);
        selectors[0] = ICommitter.commitBatchesSharedBridge.selector;
        cuts[1] = _cut(address(new CommitterFacet(block.chainid)), selectors);
        selectors = new bytes4[](1);
        selectors[0] = IExecutor.proveBatchesSharedBridge.selector;
        cuts[2] = _cut(address(new ExecutorFacet()), selectors);
        selectors = new bytes4[](6);
        selectors[0] = IGetters.disabledProofSystems.selector;
        selectors[1] = IGetters.getTotalBatchesCommitted.selector;
        selectors[2] = IGetters.getTotalBatchesVerified.selector;
        selectors[3] = IGetters.getVerifier.selector;
        selectors[4] = IGetters.getChainId.selector;
        selectors[5] = IGetters.getProofMode.selector;
        cuts[3] = _cut(address(new GettersFacet()), selectors);
        result = address(
            new DiamondProxy(
                block.chainid,
                Diamond.DiamondCutData({
                    facetCuts: cuts,
                    initAddress: address(new DiamondInit(_isZKsyncOS)),
                    initCalldata: abi.encodeCall(DiamondInit.initialize, (init))
                })
            )
        );
        address daValidator = address(new ValidiumL1DAValidator());
        vm.prank(owner);
        IAdmin(result).setDAValidatorPair(daValidator, L2DACommitmentScheme.EMPTY_NO_DA);
    }

    function _cut(address _facet, bytes4[] memory _selectors) internal pure returns (Diamond.FacetCut memory) {
        return Diamond.FacetCut({facet: _facet, action: Diamond.Action.Add, isFreezable: false, selectors: _selectors});
    }

    function _commit(
        address _chain,
        IExecutor.StoredBatchInfo memory _previous
    ) internal returns (IExecutor.StoredBatchInfo memory batch) {
        CommitBatchInfoZKsyncOS[] memory batches = new CommitBatchInfoZKsyncOS[](1);
        batches[0].batchNumber = uint64(_previous.batchNumber + 1);
        batches[0].newStateCommitment = keccak256(abi.encode(_chain, batches[0].batchNumber));
        batches[0].chainId = IGetters(_chain).getChainId();
        batches[0].slChainId = block.chainid;
        batches[0].firstBlockTimestamp = uint64(block.timestamp);
        batches[0].lastBlockTimestamp = uint64(block.timestamp);
        batches[0].daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        batches[0].operatorDAInput = abi.encode(bytes32(0));
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeCommitBatchesDataZKsyncOS(_previous, batches);
        vm.recordLogs();
        vm.prank(validator);
        ICommitter(_chain).commitBatchesSharedBridge(_chain, from, to, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        batch.batchNumber = batches[0].batchNumber;
        batch.batchHash = batches[0].newStateCommitment;
        bool foundCommit;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == _chain && logs[i].topics[0] == ICommitter.BlockCommit.selector) {
                batch.commitment = logs[i].topics[3];
                foundCommit = true;
            }
        }
        assertTrue(foundCommit, "batch commitment event");
        assertEq(IGetters(_chain).getTotalBatchesCommitted(), batch.batchNumber);
    }

    function _proofData(
        IExecutor.StoredBatchInfo memory _previous,
        IExecutor.StoredBatchInfo memory _batch,
        uint256 _mode
    ) internal pure returns (bytes memory data) {
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _batch;
        uint256[] memory proof;
        if (_mode == ZKSYNC_OS_PLONK_VERIFICATION_TYPE) {
            proof = new uint256[](ZKSYNC_OS_PROOF_METADATA_LENGTH);
            proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE;
        } else {
            proof = new uint256[](3 + ZKSYNC_OS_PROOF_METADATA_LENGTH + ZISK_SNARK_PROOF_LENGTH);
            proof[0] = _mode;
            proof[2] = ZKSYNC_OS_PROOF_METADATA_LENGTH;
            proof[3] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE;
        }
        (, , data) = Utils.encodeProveBatchesData(_previous, batches, proof);
    }

    function _prove(
        address _chain,
        IExecutor.StoredBatchInfo memory _previous,
        IExecutor.StoredBatchInfo memory _batch
    ) internal {
        bytes memory data = _proofData(_previous, _batch, IGetters(_chain).getProofMode());
        vm.expectEmit(true, true, false, true, _chain);
        emit IExecutor.BlocksVerification(_previous.batchNumber, _batch.batchNumber);
        vm.prank(validator);
        IExecutor(_chain).proveBatchesSharedBridge(_chain, _batch.batchNumber, _batch.batchNumber, data);
        assertEq(IGetters(_chain).getTotalBatchesVerified(), _batch.batchNumber);
    }

    function _expectZiskFailure(
        address _chain,
        IExecutor.StoredBatchInfo memory _previous,
        IExecutor.StoredBatchInfo memory _batch
    ) internal {
        bytes memory data = _proofData(_previous, _batch, IGetters(_chain).getProofMode());
        vm.prank(validator);
        vm.expectRevert(MultiProofVerifier.ZiskVerificationFailed.selector);
        IExecutor(_chain).proveBatchesSharedBridge(_chain, _batch.batchNumber, _batch.batchNumber, data);
        assertEq(IGetters(_chain).getTotalBatchesVerified(), _previous.batchNumber);
    }
}
