// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {
    L2_BASE_TOKEN_HOLDER,
    L2_INTEROP_ROOT_STORAGE,
    L2_MESSAGE_VERIFICATION,
    L2_NATIVE_TOKEN_VAULT,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT
} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {InteropHandlerBase} from "./InteropHandlerBase.sol";
import {V31_INTEROP_HANDLER_L1_CHAIN_ID_SLOT} from "../InteropConstants.sol";
import {IL2InteropHandler} from "./IL2InteropHandler.sol";
import {IAtomicFlowManager} from "../../atomic-interop/IAtomicFlowManager.sol";
import {AtomicFinalityProof} from "../../atomic-interop/IAtomicInterop.sol";
import {
    BUNDLE_IDENTIFIER,
    BundleStatus,
    InteropBundle,
    InteropCall,
    L2Message,
    MessageInclusionProof
} from "../../common/Messaging.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";
import {INTEROP_ROOT_WRITERS_FEATURE, L1_TO_L2_INTEROP_FEATURE} from "../../common/Config.sol";
import {MessageHashing} from "../../common/libraries/MessageHashing.sol";
import {IL2Bridgehub} from "../../core/bridgehub/IL2Bridgehub.sol";
import {
    ChainFeatureNotEnabled,
    InteropCounterpartsNotSet,
    MessageNotIncluded,
    NotSettlingOnL1,
    OneWayBundleNotSingleCall,
    OneWayCallNotToAssetRouter,
    OneWayCallValueNotZero,
    ProofNotSelfRooted,
    UnauthorizedMessageSender,
    WriterRootNotCurrent
} from "../InteropErrors.sol";

/// @title L2InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev L2 system contract that serves as the entry-point for executing, verifying and unbundling interop bundles.
/// The generic bundle logic lives in `InteropHandlerBase`; this contract wires in the L2 system-contract
/// behaviour and the **atomic** execution model: L2->L2 interop is proven via the AtomicFlowManager's IMT
/// (`AtomicFinalityProof`), not via L1 message inclusion (public L2->L2 interop was removed). The one exception is
/// {executeBundle}, for one-way bundles of the chains this chain has interop counterparts for.
contract L2InteropHandler is InteropHandlerBase, IL2InteropHandler {
    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Locks the reentrancy guard. Called once by the complex upgrader during genesis/upgrade.
    /// @dev The handler holds no configurable state; this only locks the guard (which also prevents a second
    /// initialization via `SlotOccupied`).
    function initL2() public reentrancyGuardInitializer onlyUpgrader {}

    /// @notice Clears the L1 chain id that mainnet v31's handler left outside the current storage layout.
    /// @dev See {protocol-docs/interop/architecture.md#l2interophandler-storage-across-the-v31--v33-upgrade}.
    function updateL2() public onlyUpgrader {
        uint256 v31L1ChainIdSlot = V31_INTEROP_HANDLER_L1_CHAIN_ID_SLOT;
        assembly {
            sstore(v31L1ChainIdSlot, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                    Atomic execution / verification
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a full atomic interop bundle. Instead of an L1-message inclusion proof it requires
    /// (via the AtomicFlowManager) that every leg of the flow was committed in its source chain's IMT before
    /// the deadline, and that this bundle is one of the flow's legs.
    /// @dev No gateway-settlement requirement: an atomic bundle's cross-chain binding comes from the per-leg
    /// IMT inclusion proofs authenticated against the interop root. This release supports only L1 as the
    /// settlement layer — the flow's `settlementLayerChainId` must equal the L1 chain id, enforced in
    /// {AtomicFlowManager}/{AtomicInteropProof} (`ManagerSettlementLayerNotL1`). No
    /// nonReentrant guard: replay safety is by CEI (`_markFullyExecutedAndRun` sets `FullyExecuted` before
    /// running any call), so a reentrant call for this bundle hits the status check; a global lock would also
    /// block legitimate nested interop.
    /// @param _bundle ABI-encoded InteropBundle to execute (carries the `atomicBundle` attribute at send time).
    /// @param _finality The flow definition (`flowId`, legs, deadline) + one IMT inclusion proof per leg.
    function executeAtomicBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) public override {
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        // Shared pre-gate validation (pause/permission/executability).
        _validateExecutable(bundleHash, interopBundle, status);

        // Destination-context gate, explicit here since the atomic execute path has no verify step to carry it.
        // `proofChainId` is the bundle's own `sourceChainId` (self-binding), so the source-chain sub-check is a
        // no-op; source-chain authenticity is instead established by `requireFlowFinalized` below.
        _validateBundleDestinationContext(bundleHash, interopBundle, interopBundle.sourceChainId);

        // Atomicity gate: prove the whole flow was committed before the deadline. Skipped if already verified.
        if (status != BundleStatus.Verified) {
            IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).requireFlowFinalized(bundleHash, _finality);
        }

        _markFullyExecutedAndRun(bundleHash, interopBundle);
    }

    /// @notice Verifies receipt of an atomic bundle without executing its calls, enabling the verify->unbundle flow.
    /// @param _bundle ABI-encoded InteropBundle to verify.
    /// @param _finality The flow definition + one IMT inclusion proof per leg.
    function verifyAtomicBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) public override {
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        _validateVerifiable(bundleHash, interopBundle, interopBundle.sourceChainId, status);

        // Atomicity gate, then mark verified.
        IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).requireFlowFinalized(bundleHash, _finality);

        _markVerified(bundleHash);
    }

    /*//////////////////////////////////////////////////////////////
                        One-way bundle execution
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL2InteropHandler
    function executeBundle(bytes calldata _bundle, MessageInclusionProof calldata _proof) external override {
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        _validateExecutable(bundleHash, interopBundle, status);
        _validateVerifiable(bundleHash, interopBundle, _proof.chainId, status);
        bool sourceIsL1 = _checkOneWaySource(_proof.chainId, _proof.message.sender);

        require(interopBundle.calls.length == 1, OneWayBundleNotSingleCall(interopBundle.calls.length));
        InteropCall memory interopCall = interopBundle.calls[0];
        require(interopCall.to == L2_ASSET_ROUTER_ADDR, OneWayCallNotToAssetRouter(interopCall.to));
        require(interopCall.value == 0, OneWayCallValueNotZero(interopCall.value));

        require(
            L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
                _chainId: _proof.chainId,
                _blockOrBatchNumber: _proof.l1BatchNumber,
                _index: _proof.l2MessageIndex,
                // The proven data is the bundle being executed, whatever data the proof carries.
                _message: L2Message({
                    txNumberInBatch: _proof.message.txNumberInBatch,
                    sender: _proof.message.sender,
                    data: bytes.concat(BUNDLE_IDENTIFIER, _bundle)
                }),
                _proof: _proof.proof
            }),
            MessageNotIncluded()
        );
        _checkProofRoot(_proof.chainId, _proof.proof, sourceIsL1);

        _markFullyExecutedAndRun(bundleHash, interopBundle);
    }

    /// @dev Reverts unless the proof, already verified, ends at a root of `_sourceChainId` itself that still counts.
    /// See {protocol-docs/interop.md#executing-a-one-way-bundle-on-an-l2}.
    function _checkProofRoot(uint256 _sourceChainId, bytes32[] calldata _proof, bool _sourceIsL1) internal view {
        MessageHashing.SettlementLayerReference memory root = MessageHashing.readSettlementLayerReference(_proof);
        require(
            root.settlementLayerChainId == _sourceChainId,
            ProofNotSelfRooted(_sourceChainId, root.settlementLayerChainId)
        );
        if (!_sourceIsL1) {
            require(
                L2_INTEROP_ROOT_STORAGE.isCurrentWriterRoot(_sourceChainId, root.settlementLayerBatchNumber),
                WriterRootNotCurrent(_sourceChainId, root.settlementLayerBatchNumber)
            );
        }
    }

    /// @dev Reverts unless this chain has interop counterparts for `_sourceChainId`, the feature behind them is still
    /// enabled, and `_messageSender` is the source's interop center.
    /// @return sourceIsL1 Whether the source is the chain's L1, rather than a writer's source chain.
    function _checkOneWaySource(
        uint256 _sourceChainId,
        address _messageSender
    ) internal view returns (bool sourceIsL1) {
        IL2Bridgehub bridgehub = IL2Bridgehub(L2_BRIDGEHUB_ADDR);
        address interopCenter = bridgehub.interopCounterparts(_sourceChainId).interopCenter;
        require(interopCenter != address(0), InteropCounterpartsNotSet(_sourceChainId));

        uint256 l1ChainId = bridgehub.L1_CHAIN_ID();
        sourceIsL1 = _sourceChainId == l1ChainId;
        bytes32 feature = sourceIsL1 ? L1_TO_L2_INTEROP_FEATURE : INTEROP_ROOT_WRITERS_FEATURE;
        require(bridgehub.isChainFeatureEnabled(feature), ChainFeatureNotEnabled(feature));
        if (sourceIsL1) {
            // A bundle of L1 mints like a deposit, which the asset tracker counts only while the chain settles on
            // L1. See {protocol-docs/bridging.md#one-way-bundles-and-the-deposit-accounting}.
            uint256 settlementLayerChainId = L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId();
            require(settlementLayerChainId == l1ChainId, NotSettlingOnL1(settlementLayerChainId));
        }

        require(_messageSender == interopCenter, UnauthorizedMessageSender(interopCenter, _messageSender));
    }

    /*//////////////////////////////////////////////////////////////
                    receiveMessage dispatch hooks
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc InteropHandlerBase
    function _getExecuteBundleSelector() internal pure override returns (bytes4) {
        return this.executeAtomicBundle.selector;
    }

    /// @inheritdoc InteropHandlerBase
    function _getVerifyBundleSelector() internal pure override returns (bytes4) {
        return this.verifyAtomicBundle.selector;
    }

    /// @inheritdoc InteropHandlerBase
    function _receiveExecuteBundle(
        bytes calldata _payload,
        uint256 _senderChainId,
        address _senderAddress,
        bytes calldata _sender
    ) internal override {
        (bytes memory bundle, AtomicFinalityProof memory finality) = abi.decode(
            _payload[4:],
            (bytes, AtomicFinalityProof)
        );

        // Enforce the bundle's execution-address permission against the wrapped message's sender.
        (InteropBundle memory interopBundle, bytes32 bundleHash, ) = _getBundleData(bundle);
        _requireRescueExecutionAllowed({
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _senderChainId: _senderChainId,
            _senderAddress: _senderAddress,
            _sender: _sender
        });

        this.executeAtomicBundle(bundle, finality);
    }

    /// @inheritdoc InteropHandlerBase
    function _receiveVerifyBundle(bytes calldata _payload) internal override {
        (bytes memory bundle, AtomicFinalityProof memory finality) = abi.decode(
            _payload[4:],
            (bytes, AtomicFinalityProof)
        );

        // Bundle verification is permissionless
        this.verifyAtomicBundle(bundle, finality);
    }

    /*//////////////////////////////////////////////////////////////
                        Environment-specific hooks
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc InteropHandlerBase
    function _handleCallValue(uint256 _value, uint256 _sourceChainId) internal override {
        if (_value > 0) {
            // Transfer base tokens from the BaseTokenHolder instead of minting.
            L2_BASE_TOKEN_HOLDER.give(address(this), _value, _sourceChainId);
        }
    }

    /// @inheritdoc InteropHandlerBase
    function _getExpectedDestinationBaseTokenAssetId() internal view override returns (bytes32) {
        return L2_NATIVE_TOKEN_VAULT.BASE_TOKEN_ASSET_ID();
    }

    /// @notice Allows the contract to receive native ETH from L2_BASE_TOKEN_HOLDER.
    /// @dev This is required because L2_BASE_TOKEN_HOLDER.give() transfers ETH to this contract
    ///      before forwarding it to the interop call recipient.
    receive() external payable {
        if (msg.sender != address(L2_BASE_TOKEN_HOLDER)) {
            revert Unauthorized(msg.sender);
        }
    }
}
