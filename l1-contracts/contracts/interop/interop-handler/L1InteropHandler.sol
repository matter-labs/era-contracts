// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {InteropHandlerBase} from "./InteropHandlerBase.sol";
import {IL1InteropHandler, TRANSIENT_SETTLEMENT_LAYER_SLOT} from "./IL1InteropHandler.sol";

import {InteropCall, MessageInclusionProof} from "../../common/Messaging.sol";
import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {MessageHashing, ProofData} from "../../common/libraries/MessageHashing.sol";
import {TransientPrimitivesLib} from "../../common/libraries/TransientPrimitives/TransientPrimitives.sol";
import {IMessageRootBase} from "../../core/message-root/IMessageRoot.sol";
import {InteropWithdrawalNonZeroValue} from "../../bridge/L1BridgeContractErrors.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";

/// @title L1InteropHandler
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L1-side interop handler. It executes L2 -> L1 withdrawal bundles through the shared
/// `InteropHandlerBase.executeBundle` interface (symmetric to the L2 `InteropHandler`): a withdrawal is a single-call
/// interop bundle emitted by the L2 InteropCenter whose only call targets the L1 asset router's `finalizeDeposit` via
/// ERC-7786 `receiveMessage`. This contract additionally owns the transient settlement-layer slot that the
/// `L1AssetTracker` consumes while attributing withdrawals and failed deposits.
/// @dev Deployed behind a proxy on L1.
contract L1InteropHandler is InteropHandlerBase, IL1InteropHandler {
    /// @dev MessageRoot smart contract that is used to prove message inclusion.
    IMessageRootBase public immutable MESSAGE_ROOT;

    /// @dev Address of the L1 nullifier, the only contract allowed to record the transient settlement layer
    /// for its failed-deposit recovery flow.
    address public override l1Nullifier;

    /// @notice Checks that the message sender is the L1 nullifier.
    modifier onlyNullifier() {
        require(msg.sender == l1Nullifier, Unauthorized(msg.sender));
        _;
    }

    /// @dev Contract is expected to be used as a proxy implementation.
    /// @dev Locking the reentrancy guard in the constructor prevents the implementation from being initialized.
    constructor(IMessageRootBase _messageRoot) reentrancyGuardInitializer {
        MESSAGE_ROOT = _messageRoot;
    }

    /// @notice Initializes the contract behind its proxy.
    /// @param _l1ChainId The chain ID of L1.
    /// @param _l1Nullifier The address of the L1 nullifier.
    function initialize(uint256 _l1ChainId, address _l1Nullifier) external reentrancyGuardInitializer {
        require(_l1Nullifier != address(0), Unauthorized(_l1Nullifier));
        L1_CHAIN_ID = _l1ChainId;
        l1Nullifier = _l1Nullifier;
    }

    /// @notice Not supported on L1: the L1 interop handler is initialized via `initialize` behind a proxy.
    function initL2(uint256) external view {
        revert Unauthorized(msg.sender);
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev Proves the withdrawal bundle's inclusion via the L1 MessageRoot and records the settlement layer that
    /// processed the proof in transient storage for the `L1AssetTracker`.
    function _proveInclusion(MessageInclusionProof memory _proof) internal override returns (bool) {
        bool success = MESSAGE_ROOT.proveL2MessageInclusionShared({
            _chainId: _proof.chainId,
            _blockOrBatchNumber: _proof.l1BatchNumber,
            _index: _proof.l2MessageIndex,
            _message: _proof.message,
            _proof: _proof.proof
        });
        if (!success) {
            return false;
        }

        bytes32 leaf = MessageHashing.getLeafHashFromMessage(_proof.message);
        ProofData memory proofData = MESSAGE_ROOT.getProofData({
            _chainId: _proof.chainId,
            _batchNumber: _proof.l1BatchNumber,
            _leafProofMask: _proof.l2MessageIndex,
            _leaf: leaf,
            _proof: _proof.proof
        });
        _setTransientSettlementLayer(proofData.settlementLayerChainId, _proof.l1BatchNumber);
        return true;
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev L1 has no settlement-layer restriction: it is the base layer where withdrawals are ultimately claimed.
    // solhint-disable-next-line no-empty-blocks
    function _settlementGuard() internal view override {}

    /// @inheritdoc InteropHandlerBase
    /// @dev Withdrawals carry the amount inside the `finalizeDeposit` transfer data, never as call value.
    function _handleCallValue(uint256 _value, uint256 /* _sourceChainId */) internal pure override {
        require(_value == 0, InteropWithdrawalNonZeroValue(_value));
    }

    /// @inheritdoc InteropHandlerBase
    /// @dev No post-execution accounting message is needed on L1.
    // solhint-disable-next-line no-empty-blocks
    function _afterCallExecuted(
        bytes32 /* _destinationBaseTokenAssetId */,
        InteropCall memory /* _interopCall */
    ) internal override {}

    /// @inheritdoc InteropHandlerBase
    /// @dev On L1 the base token is ETH; withdrawal bundles destined for L1 carry L1's ETH asset ID.
    function _expectedDestinationBaseTokenAssetId() internal view override returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
    }

    /// @inheritdoc IL1InteropHandler
    function setTransientSettlementLayer(
        uint256 _settlementLayerChainId,
        uint256 _l2BatchNumber
    ) external override onlyNullifier {
        _setTransientSettlementLayer(_settlementLayerChainId, _l2BatchNumber);
    }

    /// @inheritdoc IL1InteropHandler
    function getTransientSettlementLayer() external view override returns (uint256, uint256) {
        return (
            TransientPrimitivesLib.getUint256(TRANSIENT_SETTLEMENT_LAYER_SLOT),
            TransientPrimitivesLib.getUint256(TRANSIENT_SETTLEMENT_LAYER_SLOT + 1)
        );
    }

    /// @notice Records the settlement layer that processed the current proof in transient storage.
    /// @dev The value is consumed within the same transaction by the `L1AssetTracker` and cleared afterwards.
    function _setTransientSettlementLayer(uint256 _settlementLayerChainId, uint256 _l2BatchNumber) internal {
        TransientPrimitivesLib.set(TRANSIENT_SETTLEMENT_LAYER_SLOT, _settlementLayerChainId);
        TransientPrimitivesLib.set(TRANSIENT_SETTLEMENT_LAYER_SLOT + 1, _l2BatchNumber);
        emit TransientSettlementLayerSet(_settlementLayerChainId);
    }
}
