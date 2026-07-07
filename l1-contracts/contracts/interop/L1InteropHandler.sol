// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {InteropHandlerBase} from "./InteropHandlerBase.sol";
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, L2Message, MessageInclusionProof} from "../common/Messaging.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";
import {MessageHashing, ProofData} from "../common/libraries/MessageHashing.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";
import {
    InteropWithdrawalNonZeroValue,
    InteropWithdrawalNotSingleCall,
    InteropWithdrawalWrongTarget
} from "../bridge/L1BridgeContractErrors.sol";

/// @dev Minimal interface for recording the withdrawal settlement context in the L1AssetTracker.
interface IL1AssetTrackerTransient {
    function setTransientSettlementLayer(uint256 _settlementLayerChainId, uint256 _l2BatchNumber) external;
}

/// @title L1InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Executes L2->L1 withdrawal bundles on L1 using the same bundle machinery as the L2
/// `InteropHandler` (see `InteropHandlerBase`), so the interop wire format is parsed in a single
/// place across layers. The L1 environment differs from L2 as follows:
/// - inclusion is proven against the L1 `MessageRoot`;
/// - execution is permissionless and replay-protected solely by the bundle status (bundle-hash keyed);
/// - before executing, the handler records the withdrawal's settlement context in the
///   `L1AssetTracker`, which attributes the chain-balance accounting during `finalizeDeposit`;
/// - the only allowed call target is the L1 asset router (an L2->L1 bundle is exactly one
///   `finalizeDeposit` call), and no value can ride the call (the withdrawn amount is carried inside
///   the transfer data);
/// - there is no unbundling and no post-execution GWAssetTracker accounting on L1.
contract L1InteropHandler is InteropHandlerBase {
    /// @dev The L1 MessageRoot used to prove L2->L1 message inclusion and resolve proof data.
    IMessageRootBase public immutable MESSAGE_ROOT;

    /// @dev The L1 asset router — the only allowed call target of an L2->L1 withdrawal bundle.
    address public immutable L1_ASSET_ROUTER;

    /// @dev The L1 asset tracker, which receives the settlement context of each withdrawal.
    IL1AssetTrackerTransient public immutable L1_ASSET_TRACKER;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        IMessageRootBase _messageRoot,
        address _l1AssetRouter,
        IL1AssetTrackerTransient _l1AssetTracker
    ) reentrancyGuardInitializer {
        require(address(_messageRoot) != address(0), ZeroAddress());
        require(_l1AssetRouter != address(0), ZeroAddress());
        require(address(_l1AssetTracker) != address(0), ZeroAddress());
        MESSAGE_ROOT = _messageRoot;
        L1_ASSET_ROUTER = _l1AssetRouter;
        L1_ASSET_TRACKER = _l1AssetTracker;
    }

    /// @dev Initializes the proxy: on L1 the handler runs on L1 itself.
    function initialize() external reentrancyGuardInitializer {
        L1_CHAIN_ID = block.chainid;
    }

    /// @notice Executes an L2->L1 withdrawal bundle.
    /// @dev Before the base execution flow runs, the withdrawal's settlement context is recorded in
    /// the `L1AssetTracker`, which reads it while attributing the chain-balance accounting of the
    /// bundle's `finalizeDeposit` call.
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) public override nonReentrant {
        _recordWithdrawalAttribution(_bundle, _proof);
        super.executeBundle(_bundle, _proof);
    }

    /// @notice Resolves the settlement context of the withdrawal message and records it transiently
    /// in the `L1AssetTracker`.
    /// @dev Reconstructs the same L2->L1 message the inclusion proof commits to (identifier prefix
    /// plus the bundle). The recorded values only matter if the bundle execution (which includes the
    /// inclusion proof) succeeds.
    function _recordWithdrawalAttribution(bytes memory _bundle, MessageInclusionProof memory _proof) internal {
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: _proof.message.txNumberInBatch,
            sender: _proof.message.sender,
            data: bytes.concat(BUNDLE_IDENTIFIER, _bundle)
        });

        bytes32 leaf = MessageHashing.getLeafHashFromMessage(l2ToL1Message);
        ProofData memory proofData = MESSAGE_ROOT.getProofData({
            _chainId: _proof.chainId,
            _batchNumber: _proof.l1BatchNumber,
            _leafProofMask: _proof.l2MessageIndex,
            _leaf: leaf,
            _proof: _proof.proof
        });
        L1_ASSET_TRACKER.setTransientSettlementLayer(proofData.settlementLayerChainId, _proof.l1BatchNumber);
    }

    /*//////////////////////////////////////////////////////////////
                        Environment-specific hooks
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdrawal execution on L1 is permissionless (unless the bundle specifies an execution
    /// address): replay protection is the bundle status, and the settlement-context attribution is
    /// recorded by this contract itself in `executeBundle`.
    function _ensureBundleProcessingAllowed() internal view override {}

    /// @notice Proves message inclusion via the L1 MessageRoot.
    function _proveMessageInclusion(MessageInclusionProof memory _proof) internal view override returns (bool) {
        return
            MESSAGE_ROOT.proveL2MessageInclusionShared({
                _chainId: _proof.chainId,
                _blockOrBatchNumber: _proof.l1BatchNumber,
                _index: _proof.l2MessageIndex,
                _message: _proof.message,
                _proof: _proof.proof
            });
    }

    /// @notice L1's base token is ETH: bundles destined for L1 carry the L1-native ETH asset id
    /// (see `InteropCenter._sendBundle`).
    function _destinationBaseTokenAssetId() internal view override returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
    }

    /// @notice No value can ride an L2->L1 withdrawal call: the withdrawn amount is carried inside the
    /// `finalizeDeposit` transfer data (the InteropCenter enforces this at send time as well).
    function _fundCallValue(uint256 _value, uint256 /* _sourceChainId */) internal pure override {
        revert InteropWithdrawalNonZeroValue(_value);
    }

    /// @notice An L2->L1 withdrawal is a single-call bundle (one `finalizeDeposit` per withdrawal).
    function _validateBundle(InteropBundle memory _interopBundle) internal view override {
        require(_interopBundle.calls.length == 1, InteropWithdrawalNotSingleCall());
    }

    /// @notice An L2->L1 withdrawal bundle is exactly one `finalizeDeposit` call to the L1 asset router;
    /// arbitrary call targets are not executable on L1.
    function _validateCall(InteropCall memory _interopCall) internal view override {
        require(_interopCall.to == L1_ASSET_ROUTER, InteropWithdrawalWrongTarget());
    }

    /// @notice No post-execution accounting on L1 (the L1AssetTracker accounts during `finalizeDeposit`
    /// itself, attributed via the transient settlement-layer context recorded in `executeBundle`).
    function _afterCallExecuted(bytes32, InteropCall memory) internal override {}
}
