// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {
    L2_BASE_TOKEN_HOLDER,
    L2_NATIVE_TOKEN_VAULT,
    L2_MESSAGE_VERIFICATION,
    L2_COMPLEX_UPGRADER_ADDR
} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {InteropHandlerBase} from "./InteropHandlerBase.sol";
import {IAtomicFlowManager} from "../../atomic-interop/IAtomicFlowManager.sol";
import {AtomicFinalityProof} from "../../atomic-interop/IAtomicInterop.sol";
import {BundleStatus, CallStatus, InteropBundle, MessageInclusionProof} from "../../common/Messaging.sol";
import {BundleAlreadyProcessed, ExecutingNotAllowed} from "../InteropErrors.sol";
import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";

/// @title L2InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev L2 system contract that serves as the entry-point for executing, verifying and unbundling interop bundles.
/// The generic bundle logic lives in `InteropHandlerBase`; this contract wires in the L2 system-contract behaviour.
contract L2InteropHandler is InteropHandlerBase {
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

    /// @notice Executes an **atomic interop** bundle (L2->L2 only). Mirrors {executeBundle}, but instead of
    /// an L1-message inclusion proof it requires (via the AtomicFlowManager) that every leg of the flow was
    /// committed in its source chain's IMT before the deadline. Atomic bundles are never published to L1, so
    /// this is their only execution entry point; there is no atomic verify path.
    /// @dev No gateway-settlement requirement (unlike public {executeBundle}): an atomic bundle's cross-chain
    /// binding comes from the per-leg IMT inclusion proofs authenticated against the interop root, valid on any
    /// settlement layer. No `nonReentrant` guard, matching {executeBundle}: replay safety is by CEI (status is
    /// set to `FullyExecuted` before any call runs), so a reentrant call for this bundle hits the status check.
    /// @param _bundle ABI-encoded InteropBundle to execute (carries the `atomicBundle` attribute at send time).
    /// @param _finality The flow definition (`flowId`, legs, deadline) + one IMT inclusion proof per leg.
    function executeAtomicBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) public {
        _ensureNotPaused();

        // Decode the bundle, compute its hash, read its status.
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        // An atomic bundle is never published to L1, so its source chain id is the bundle's own field; the
        // cross-chain binding comes from the IMT inclusion proof (the atomicity gate) below.
        _validateBundleDestinationContext(bundleHash, interopBundle, interopBundle.sourceChainId);

        // Execution-address permission gate (mirrors {executeBundle}): permissionless when unset, otherwise
        // only that address (on this chain, or chain-agnostic via chainId 0) or this contract itself (when the
        // execution was initiated through `receiveMessage`) may execute.
        if (interopBundle.bundleAttributes.executionAddress.length != 0) {
            (uint256 executionChainId, address executionAddress) = InteroperableAddress.parseEvmV1(
                interopBundle.bundleAttributes.executionAddress
            );
            require(
                (msg.sender == address(this) ||
                    ((executionChainId == block.chainid || executionChainId == 0) && executionAddress == msg.sender)),
                ExecutingNotAllowed(
                    bundleHash,
                    InteroperableAddress.formatEvmV1(block.chainid, msg.sender),
                    interopBundle.bundleAttributes.executionAddress
                )
            );
        }

        // Atomic bundles have no verify path (they were never published to L1), so only a fresh bundle may be
        // executed; replay is then prevented by marking it FullyExecuted below.
        require(status == BundleStatus.Unreceived, BundleAlreadyProcessed(bundleHash));

        // Atomicity gate: replaces {executeBundle}'s L1-message inclusion proof. Proves every leg of the flow
        // was committed in its source chain's IMT before the deadline, and that this bundle is one of the legs.
        IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).requireFlowFinalized(bundleHash, _finality);

        // Mark fully executed (CEI) then run all calls; a failing call reverts the whole flow.
        bundleStatus[bundleHash] = BundleStatus.FullyExecuted;
        uint256 callsLength = interopBundle.calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            callStatus[bundleHash][i] = CallStatus.Executed;
        }
        _executeCalls({
            _sourceChainId: interopBundle.sourceChainId,
            _bundleHash: bundleHash,
            _interopBundle: interopBundle,
            _executeAllCalls: true,
            _providedCallStatus: new CallStatus[](0)
        });

        emit BundleExecuted(bundleHash);
    }

    /// @inheritdoc InteropHandlerBase
    function _proveInclusion(MessageInclusionProof memory _proof) internal view override returns (bool) {
        return
            L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared({
                _chainId: _proof.chainId,
                _blockOrBatchNumber: _proof.l1BatchNumber,
                _index: _proof.l2MessageIndex,
                _message: _proof.message,
                _proof: _proof.proof
            });
    }

    /// @inheritdoc InteropHandlerBase
    function _handleCallValue(uint256 _value, uint256 _sourceChainId) internal override {
        if (_value > 0) {
            // Transfer base tokens from the BaseTokenHolder instead of minting.
            L2_BASE_TOKEN_HOLDER.give(address(this), _value, _sourceChainId);
        }
    }

    /// @inheritdoc InteropHandlerBase
    function _expectedDestinationBaseTokenAssetId() internal view override returns (bytes32) {
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
