// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ExecutorTest} from "./_Executor_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";

import {ZKsyncOSBatchMirror} from "contracts/state-transition/batch-mirror/ZKsyncOSBatchMirror.sol";
import {
    ZKsyncOSBatchMirrorInitParams,
    ZKsyncOSChainConfig
} from "contracts/state-transition/chain-interfaces/IZKsyncOSBatchMirror.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {ZKsyncOSBatchCommitment} from "contracts/state-transition/libraries/ZKsyncOSBatchCommitment.sol";
import {MultiProofTestnetVerifier} from "contracts/state-transition/verifiers/MultiProofTestnetVerifier.sol";
import {MultiProofVerifier} from "contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";
import {AcceptingVerifier} from "contracts/dev-contracts/test/AcceptingVerifier.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {PUBLIC_INPUT_SHIFT} from "contracts/common/Config.sol";

/// @notice Commits and proves batches on a real ZKsync OS chain diamond, then replays the exact calldata into
/// a `ZKsyncOSBatchMirror` on another host stack. The mirror must end up with the settlement layer's stored
/// batch hashes, which also checks that the `CommitterFacet` stores what `ZKsyncOSBatchCommitment` derives.
contract BatchMirrorReplayTest is ExecutorTest {
    uint256 internal constant BATCHES = 3;

    L1MessageRoot internal hostMessageRoot;
    ZKsyncOSBatchMirror internal mirror;
    address internal relayer = makeAddr("relayer");

    function setUp() public {
        address hostBridgehubOwner = makeAddr("hostBridgehubOwner");
        L1Bridgehub hostBridgehub = new L1Bridgehub(hostBridgehubOwner, 100);
        address hostChainAssetHandler = makeAddr("hostChainAssetHandler");
        hostMessageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(address(hostBridgehub), hostChainAssetHandler)),
                    makeAddr("hostMessageRootProxyAdmin"),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );
        address hostChainTypeManager = makeAddr("hostChainTypeManager");
        vm.startPrank(hostBridgehubOwner);
        hostBridgehub.setAddresses(
            makeAddr("hostAssetRouter"),
            ICTMDeploymentTracker(makeAddr("hostCtmDeploymentTracker")),
            IMessageRootBase(address(hostMessageRoot)),
            hostChainAssetHandler,
            makeAddr("hostChainRegistrationSender")
        );
        hostBridgehub.addChainTypeManager(hostChainTypeManager);
        vm.stopPrank();

        AcceptingVerifier acceptingVerifier = new AcceptingVerifier();
        ZKsyncOSTestnetVerifier airbenderVerifier = new ZKsyncOSTestnetVerifier(acceptingVerifier);
        MultiProofVerifier multiProofVerifier = new MultiProofVerifier(airbenderVerifier, acceptingVerifier);
        MultiProofTestnetVerifier mirrorVerifier = new MultiProofTestnetVerifier(multiProofVerifier);
        ZKsyncOSBatchMirrorInitParams memory params = ZKsyncOSBatchMirrorInitParams({
            owner: owner,
            bridgehub: address(hostBridgehub),
            chainId: l2ChainId,
            settlementLayerChainId: block.chainid,
            chainTypeManager: hostChainTypeManager,
            // The fixture chain's base token is the ETH asset of this chain, which every Bridgehub registers.
            baseTokenAssetId: baseTokenAssetId,
            verifier: mirrorVerifier,
            // The configuration as the settlement layer reports it.
            chainConfig: ZKsyncOSChainConfig({
                maxTxGasLimit: getters.getZKsyncOSMaxTxGasLimit(),
                pubdataContent: getters.getPubdataContent(),
                l1TxFilteringEnabled: getters.isZKsyncOSL1TxFilteringEnabled(),
                largeContractsEnabled: getters.isZKsyncOSLargeContractsEnabled()
            }),
            anchor: genesisStoredBatchInfo
        });
        mirror = ZKsyncOSBatchMirror(
            address(
                new TransparentUpgradeableProxy(
                    address(new ZKsyncOSBatchMirror()),
                    makeAddr("mirrorProxyAdmin"),
                    abi.encodeCall(ZKsyncOSBatchMirror.initialize, (params))
                )
            )
        );
        vm.prank(owner);
        mirror.setValidator(relayer, true);
        vm.prank(hostBridgehubOwner);
        hostBridgehub.registerAlreadyDeployedZKChain(l2ChainId, address(mirror));
    }

    function test_mirrorReplaysTheSettlementLayersCalldata() public {
        assertEq(mirror.getZKsyncOSChainConfigHash(), getters.getZKsyncOSChainConfigHash());
        assertEq(mirror.storedBatchHash(0), getters.storedBatchHash(0));

        bytes[] memory commitData = new bytes[](BATCHES);
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](BATCHES);
        IExecutor.StoredBatchInfo memory previous = genesisStoredBatchInfo;
        for (uint256 i = 0; i < BATCHES; ++i) {
            CommitBatchInfoZKsyncOS memory info = newCommitBatchInfoZKsyncOS;
            info.batchNumber = uint64(i + 1);
            info.newStateCommitment = keccak256(abi.encode("state", i + 1));
            info.l2LogsTreeRoot = keccak256(abi.encode("chain batch root", i + 1));
            info.interopFeeUnits = i;
            CommitBatchInfoZKsyncOS[] memory single = new CommitBatchInfoZKsyncOS[](1);
            single[0] = info;
            uint256 from;
            uint256 to;
            (from, to, commitData[i]) = Utils.encodeCommitBatchesDataZKsyncOS(previous, single);

            _mockDAForCommit(info.batchNumber);
            vm.prank(validator);
            committer.commitBatchesSharedBridge(address(0), from, to, commitData[i]);

            batches[i] = ZKsyncOSBatchCommitment.storedBatchInfo(previous.batchHash, info, bytes32(0));
            assertEq(getters.storedBatchHash(i + 1), keccak256(abi.encode(batches[i])), "committer vs library");
            previous = batches[i];
        }

        (uint256 proveFrom, uint256 proveTo, bytes memory proofData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            batches,
            _mockProof(batches)
        );
        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), proveFrom, proveTo, proofData);
        assertEq(getters.getTotalBatchesVerified(), BATCHES);

        vm.prank(relayer);
        mirror.mirrorBatches(commitData, new bytes32[](BATCHES), proofData);

        assertEq(mirror.getTotalBatchesExecuted(), BATCHES);
        for (uint256 n = 1; n <= BATCHES; ++n) {
            assertEq(mirror.storedBatchHash(n), getters.storedBatchHash(n), "mirror vs settlement layer");
            assertEq(hostMessageRoot.chainBatchRoots(l2ChainId, n), batches[n - 1].l2LogsTreeRoot);
        }
    }

    /// @dev A `MultiProofTestnetVerifier` mock proof of `_batches`; the fixture's settlement layer accepts any proof.
    function _mockProof(IExecutor.StoredBatchInfo[] memory _batches) internal pure returns (uint256[] memory proof) {
        uint256[] memory publicInputs = new uint256[](_batches.length);
        for (uint256 i = 0; i < _batches.length; ++i) {
            publicInputs[i] = uint256(_batches[i].commitment);
        }
        proof = new uint256[](4);
        proof[0] = 3;
        proof[2] = 13;
        proof[3] = uint256(keccak256(abi.encodePacked(publicInputs))) >> PUBLIC_INPUT_SHIFT;
    }
}
