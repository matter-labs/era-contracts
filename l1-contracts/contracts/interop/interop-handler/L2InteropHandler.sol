// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2_BASE_TOKEN_HOLDER, L2_NATIVE_TOKEN_VAULT} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {L2_ATOMIC_FLOW_MANAGER_ADDR, L2_COMPLEX_UPGRADER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {InteropHandlerBase} from "./InteropHandlerBase.sol";
import {IL2InteropHandler} from "./IL2InteropHandler.sol";
import {IAtomicFlowManager} from "../../atomic-interop/IAtomicFlowManager.sol";
import {AtomicFinalityProof} from "../../atomic-interop/IAtomicInterop.sol";
import {BundleStatus, InteropBundle} from "../../common/Messaging.sol";
import {ExecutingNotAllowed} from "../InteropErrors.sol";
import {InteroperableAddress} from "../../vendor/draft-InteroperableAddress.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";

/// @title L2InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev L2 system contract that serves as the entry-point for executing, verifying and unbundling interop bundles.
/// The generic bundle logic lives in `InteropHandlerBase`; this contract wires in the L2 system-contract
/// behaviour and the **atomic** execution model: L2->L2 interop is proven via the AtomicFlowManager's IMT
/// (`AtomicFinalityProof`), not via L1 message inclusion (public L2->L2 interop was removed).
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

    /*//////////////////////////////////////////////////////////////
                    Atomic execution / verification
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a full atomic interop bundle. Instead of an L1-message inclusion proof it requires
    /// (via the AtomicFlowManager) that every leg of the flow was committed in its source chain's IMT before
    /// the deadline, and that this bundle is one of the flow's legs.
    /// @dev No gateway-settlement requirement: an atomic bundle's cross-chain binding comes from the per-leg
    /// IMT inclusion proofs authenticated against the interop root, valid on any settlement layer. No
    /// nonReentrant guard: replay safety is by CEI (`_markFullyExecutedAndRun` sets `FullyExecuted` before
    /// running any call), so a reentrant call for this bundle hits the status check; a global lock would also
    /// block legitimate nested interop.
    /// @param _bundle ABI-encoded InteropBundle to execute (carries the `atomicBundle` attribute at send time).
    /// @param _finality The flow definition (`flowId`, legs, deadline) + one IMT inclusion proof per leg.
    function executeAtomicBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) public override {
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        // Shared pre-gate validation. An atomic bundle is never published to L1, so it self-binds its own
        // source chain id: the `proofChainId` argument here is `interopBundle.sourceChainId` itself, so
        // `_validateExecutable`'s `WrongSourceChainId` check is a no-op (it compares the value to itself).
        // That is intentional — the *authenticity* of `interopBundle.sourceChainId` is not established here
        // but by `requireFlowFinalized` below, which verifies each leg's source chain via the atomic proof's
        // `legSourceChainIds` against the committed IMT.
        _validateExecutable(bundleHash, interopBundle, interopBundle.sourceChainId, status);

        // Atomicity gate: prove the whole flow was committed before the deadline. Skipped if already verified.
        if (status != BundleStatus.Verified) {
            IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).requireFlowFinalized(bundleHash, _finality);
        }

        _markFullyExecutedAndRun(bundleHash, interopBundle);
    }

    /// @notice Verifies receipt of an atomic bundle without executing its calls, enabling the verify->unbundle flow.
    /// @param _bundle ABI-encoded InteropBundle to verify.
    /// @param _finality The flow definition + one IMT inclusion proof per leg.
    function verifyBundle(bytes memory _bundle, AtomicFinalityProof calldata _finality) public override {
        (InteropBundle memory interopBundle, bytes32 bundleHash, BundleStatus status) = _getBundleData(_bundle);

        _validateVerifiable(bundleHash, interopBundle, interopBundle.sourceChainId, status);

        // Atomicity gate, then mark verified.
        IAtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).requireFlowFinalized(bundleHash, _finality);

        _markVerified(bundleHash);
    }

    /*//////////////////////////////////////////////////////////////
                    receiveMessage dispatch hooks
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc InteropHandlerBase
    function _executeBundleSelector() internal view override returns (bytes4) {
        return this.executeAtomicBundle.selector;
    }

    /// @inheritdoc InteropHandlerBase
    function _verifyBundleSelector() internal view override returns (bytes4) {
        return this.verifyBundle.selector;
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

        // Decode the bundle to get execution permissions
        (InteropBundle memory interopBundle, bytes32 bundleHash, ) = _getBundleData(bundle);
        if (interopBundle.bundleAttributes.executionAddress.length != 0) {
            (uint256 executionChainId, address executionAddress) = InteroperableAddress.parseEvmV1(
                interopBundle.bundleAttributes.executionAddress
            );
            require(
                (executionChainId == _senderChainId || executionChainId == 0) && executionAddress == _senderAddress,
                ExecutingNotAllowed(bundleHash, _sender, interopBundle.bundleAttributes.executionAddress)
            );
        }

        this.executeAtomicBundle(bundle, finality);
    }

    /// @inheritdoc InteropHandlerBase
    function _receiveVerifyBundle(bytes calldata _payload) internal override {
        (bytes memory bundle, AtomicFinalityProof memory finality) = abi.decode(
            _payload[4:],
            (bytes, AtomicFinalityProof)
        );

        // Bundle verification is permissionless
        this.verifyBundle(bundle, finality);
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
