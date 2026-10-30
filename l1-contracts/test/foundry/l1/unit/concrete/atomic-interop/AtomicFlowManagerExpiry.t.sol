// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";
import {AtomicFlowFixtures} from "./AtomicFlowFixtures.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {
    AtomicFinalityProof,
    AtomicFlow,
    AtomicFlowPreimage,
    ImtProof,
    ATOMIC_FLOW_EXPIRABLE_PREIMAGE_VERSION,
    ATOMIC_FLOW_EXPIRY_DELAY,
    ATOMIC_FLOW_PREIMAGE_VERSION
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ManagerCommittedBundleNotInFlow,
    ManagerExpirableFlowNotSingleLeg,
    ManagerFlowNotExpirable,
    ManagerFlowNotExpiredYet,
    ManagerLegSourceChainNotAllowed,
    ManagerNotInteropHandler,
    ProofSourceChainMismatch
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IMTLeafValueMismatch} from "contracts/common/L1ContractErrors.sol";
import {INTEROP_BUNDLE_VERSION, InteropBundle, InteropCall} from "contracts/common/Messaging.sol";
import {L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice The `AtomicFlowManager` checks of expiry ({protocol-docs/atomicity/expiry.md}): `recordExpiry` on the
/// destination, `authorizeExpiryRefund` on the source, and `append` of an expirable flow. The happy paths run
/// through the real handler and InteropCenter in `L2AtomicInteropExecuteTestAbstract`.
/// @dev The remote chain of each test (the leg's source for `recordExpiry`, its destination for
/// `authorizeExpiryRefund`) is modeled by the builder's oracle tree, and its proofs run end-to-end through real
/// aggregation, root import and {L2MessageVerification}. The receive filter is stubbed (see {AtomicPredeployFixture}).
contract AtomicFlowManagerExpiryTest is AtomicInteropProofBuilder {
    /// @dev The other chain of the flow: aggregatable in the settlement-layer MessageRoot, unlike this chain.
    uint256 internal constant REMOTE_CHAIN = 271;
    /// @dev A chain that is neither end of the flow.
    uint256 internal constant UNRELATED_CHAIN = 272;

    AtomicFlowManager internal manager;

    function setUp() public {
        (manager, ) = _deployAtomicPredeploys(SETTLEMENT_LAYER_CHAIN_ID, true);
        _setUpAtomicFixtures();
        _setLegSourceAllowed(REMOTE_CHAIN, true);
    }

    function _bundleBytes(uint256 _sourceChainId, uint256 _destinationChainId) internal pure returns (bytes memory) {
        return
            abi.encode(
                InteropBundle({
                    version: INTEROP_BUNDLE_VERSION,
                    sourceChainId: _sourceChainId,
                    destinationChainId: _destinationChainId,
                    destinationBaseTokenAssetId: bytes32(uint256(1)),
                    interopBundleSalt: keccak256("expiry salt"),
                    calls: new InteropCall[](0),
                    bundleAttributes: AtomicFlowFixtures.noBundleAttributes()
                })
            );
    }

    /*//////////////////////////////////////////////////////////////
                    Destination: recordExpiry
    //////////////////////////////////////////////////////////////*/

    /// @dev Moves this chain's imported L1 time to `_timestamp` by importing a root stamped with it.
    function _importRootAt(uint256 _timestamp) internal {
        vm.warp(_timestamp);
        _importInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, _freshSlBlock(), _timestamp, keccak256("later root"));
    }

    /// @dev A leg from `REMOTE_CHAIN` to this chain, committed there in time under `_preimage`, with its finality
    /// proof.
    function _remoteLegFinality(
        AtomicFlowPreimage memory _preimage
    ) internal returns (AtomicFinalityProof memory finality) {
        bytes32 flowId = AtomicFlowFixtures.flowId(_preimage);
        uint256 index = _insertCommit(AtomicFlowFixtures.commitValue(flowId, _preimage.legBundleHashes[0]));
        finality.flow = AtomicFlow({flowId: flowId, preimage: _preimage});
        finality.proofs = new ImtProof[](1);
        finality.proofs[0] = _realInclusionProof(REMOTE_CHAIN, index, DEADLINE);
    }

    function _incomingLeg() internal view returns (bytes32) {
        return keccak256(_bundleBytes(REMOTE_CHAIN, block.chainid));
    }

    /// @notice The expiry time is exclusive: a root stamped exactly `deadline + delay` is not enough.
    function test_recordExpiry_RevertWhen_ExpiryTimeNotPassed() public {
        bytes32 leg = _incomingLeg();
        AtomicFinalityProof memory finality = _remoteLegFinality(
            AtomicFlowFixtures.expirablePreimage(leg, REMOTE_CHAIN, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID)
        );
        uint256 expiresAfter = DEADLINE + ATOMIC_FLOW_EXPIRY_DELAY;
        _importRootAt(expiresAfter);

        vm.expectRevert(abi.encodeWithSelector(ManagerFlowNotExpiredYet.selector, expiresAfter, expiresAfter));
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        manager.recordExpiry(leg, finality, 0);
    }

    function test_recordExpiry_RevertWhen_FlowNotExpirable() public {
        bytes32 leg = _incomingLeg();
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.expirablePreimage(
            leg,
            REMOTE_CHAIN,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        preimage.version = ATOMIC_FLOW_PREIMAGE_VERSION;
        AtomicFinalityProof memory finality = _remoteLegFinality(preimage);
        _importRootAt(DEADLINE + ATOMIC_FLOW_EXPIRY_DELAY + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ManagerFlowNotExpirable.selector, finality.flow.flowId, ATOMIC_FLOW_PREIMAGE_VERSION)
        );
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        manager.recordExpiry(leg, finality, 0);
    }

    /// @notice A made-up preimage around a committed leg can't expire it early: one with an earlier deadline that the
    /// leg's batch still meets passes the deadline check, but its `flowId` was never committed.
    /// See {protocol-docs/atomicity/expiry.md#expiry-on-the-destination}.
    function test_recordExpiry_RevertWhen_PreimageWasNotCommitted() public {
        bytes32 leg = _incomingLeg();
        AtomicFinalityProof memory finality = _remoteLegFinality(
            AtomicFlowFixtures.expirablePreimage(leg, REMOTE_CHAIN, DEADLINE + 30 days, SETTLEMENT_LAYER_CHAIN_ID)
        );
        AtomicFlowPreimage memory forged = AtomicFlowFixtures.expirablePreimage(
            leg,
            REMOTE_CHAIN,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        bytes32 forgedFlowId = AtomicFlowFixtures.flowId(forged);
        uint256 committedValue = AtomicFlowFixtures.commitValue(finality.flow.flowId, leg);
        finality.flow = AtomicFlow({flowId: forgedFlowId, preimage: forged});
        _importRootAt(DEADLINE + ATOMIC_FLOW_EXPIRY_DELAY + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMTLeafValueMismatch.selector,
                AtomicFlowFixtures.commitValue(forgedFlowId, leg),
                committedValue
            )
        );
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        manager.recordExpiry(leg, finality, 0);
    }

    function test_recordExpiry_RevertWhen_NotInteropHandler() public {
        AtomicFinalityProof memory finality;
        vm.expectRevert(abi.encodeWithSelector(ManagerNotInteropHandler.selector, address(this)));
        manager.recordExpiry(bytes32(0), finality, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    Source: authorizeExpiryRefund
    //////////////////////////////////////////////////////////////*/

    /// @dev A single-leg `_version` flow from this chain to `REMOTE_CHAIN`, and its leg's bundle.
    function _outgoingLeg(
        bytes1 _version
    ) internal view returns (AtomicFlowPreimage memory preimage, bytes memory bundle) {
        bundle = _bundleBytes(block.chainid, REMOTE_CHAIN);
        preimage = AtomicFlowFixtures.expirablePreimage(
            keccak256(bundle),
            block.chainid,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        preimage.version = _version;
    }

    /// @dev Commits a leg from this chain to `REMOTE_CHAIN` through the production `append`.
    function _commitOutgoingLeg(bytes1 _version) internal returns (AtomicFlow memory flow, bytes memory bundle) {
        AtomicFlowPreimage memory preimage;
        (preimage, bundle) = _outgoingLeg(_version);
        flow = AtomicFlow({flowId: AtomicFlowFixtures.flowId(preimage), preimage: preimage});
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(keccak256(bundle), 0, preimage);
    }

    /// @notice The expiry must be proven in the tree of the leg's destination, and this chain must accept that chain.
    function test_authorizeExpiryRefund_RevertWhen_ProofNotFromAllowedDestination() public {
        (AtomicFlow memory flow, bytes memory bundle) = _commitOutgoingLeg(ATOMIC_FLOW_EXPIRABLE_PREIMAGE_VERSION);
        uint256 index = _insertCommit(AtomicFlowFixtures.expiryValue(flow.flowId, keccak256(bundle)));
        uint256 expiredAt = DEADLINE + ATOMIC_FLOW_EXPIRY_DELAY + 1;
        ImtProof memory fromUnrelatedChain = _realInclusionProof(UNRELATED_CHAIN, index, expiredAt);
        ImtProof memory fromDestination = _realInclusionProof(REMOTE_CHAIN, index, expiredAt);

        vm.expectRevert(abi.encodeWithSelector(ProofSourceChainMismatch.selector, REMOTE_CHAIN, UNRELATED_CHAIN));
        manager.authorizeExpiryRefund(flow, bundle, fromUnrelatedChain);

        _setLegSourceAllowed(REMOTE_CHAIN, false);
        vm.expectRevert(abi.encodeWithSelector(ManagerLegSourceChainNotAllowed.selector, REMOTE_CHAIN));
        manager.authorizeExpiryRefund(flow, bundle, fromDestination);
    }

    function test_authorizeExpiryRefund_RevertWhen_FlowNotExpirable() public {
        (AtomicFlow memory flow, bytes memory bundle) = _commitOutgoingLeg(ATOMIC_FLOW_PREIMAGE_VERSION);
        ImtProof memory expiry;

        vm.expectRevert(
            abi.encodeWithSelector(ManagerFlowNotExpirable.selector, flow.flowId, ATOMIC_FLOW_PREIMAGE_VERSION)
        );
        manager.authorizeExpiryRefund(flow, bundle, expiry);
    }

    function test_authorizeExpiryRefund_RevertWhen_BundleIsNotTheLeg() public {
        (AtomicFlow memory flow, ) = _commitOutgoingLeg(ATOMIC_FLOW_EXPIRABLE_PREIMAGE_VERSION);
        bytes memory otherBundle = _bundleBytes(block.chainid, UNRELATED_CHAIN);
        ImtProof memory expiry;

        vm.expectRevert(
            abi.encodeWithSelector(ManagerCommittedBundleNotInFlow.selector, flow.flowId, keccak256(otherBundle))
        );
        manager.authorizeExpiryRefund(flow, otherBundle, expiry);
    }

    /*//////////////////////////////////////////////////////////////
                    append of an expirable flow
    //////////////////////////////////////////////////////////////*/

    function test_append_expirableFlowEmitsExpirableFlowCommitted() public {
        (AtomicFlowPreimage memory preimage, bytes memory bundle) = _outgoingLeg(
            ATOMIC_FLOW_EXPIRABLE_PREIMAGE_VERSION
        );

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.ExpirableFlowCommitted(AtomicFlowFixtures.flowId(preimage), keccak256(bundle));
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(keccak256(bundle), 0, preimage);
    }

    function test_append_RevertWhen_ExpirableFlowHasTwoLegs() public {
        bytes32 leg = keccak256("local leg");
        (AtomicFlowPreimage memory preimage, , ) = AtomicFlowFixtures.twoLegPreimage({
            _legA: leg,
            _chainA: block.chainid,
            _legB: keccak256("other leg"),
            _chainB: REMOTE_CHAIN,
            _deadline: DEADLINE,
            _settlementLayerChainId: SETTLEMENT_LAYER_CHAIN_ID
        });
        preimage.version = ATOMIC_FLOW_EXPIRABLE_PREIMAGE_VERSION;

        vm.expectRevert(abi.encodeWithSelector(ManagerExpirableFlowNotSingleLeg.selector, 2));
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(leg, 0, preimage);
    }
}
