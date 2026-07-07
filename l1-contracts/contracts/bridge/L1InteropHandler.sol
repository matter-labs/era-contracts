// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {AssetRouterBase} from "./asset-router/AssetRouterBase.sol";
import {IL1AssetRouter} from "./asset-router/IL1AssetRouter.sol";
import {
    FinalizeL1DepositParams,
    IL1InteropHandler,
    TRANSIENT_SETTLEMENT_LAYER_SLOT
} from "./interfaces/IL1InteropHandler.sol";

import {BUNDLE_IDENTIFIER, L2Message} from "../common/Messaging.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {L2_INTEROP_CENTER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {
    AddressAlreadySet,
    InvalidProof,
    InvalidSelector,
    Unauthorized,
    WithdrawalAlreadyFinalized,
    ZeroAddress
} from "../common/L1ContractErrors.sol";
import {WrongL2Sender, WrongMsgLength} from "./L1BridgeContractErrors.sol";
import {MessageHashing, ProofData} from "../common/libraries/MessageHashing.sol";
import {TransientPrimitivesLib} from "../common/libraries/TransientPrimitives/TransientPrimitives.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Finalizes L2 -> L1 withdrawals on L1. Every withdrawal (base token and ERC20) is emitted by the L2
/// InteropCenter as a single-call interop bundle; this contract proves the bundle's inclusion, parses it, enforces
/// replay protection and dispatches the finalization to the L1 asset router. It also owns the transient
/// settlement-layer slot that the `L1AssetTracker` consumes while attributing withdrawals and failed deposits.
/// @dev Designed for use with a proxy for upgradability.
contract L1InteropHandler is IL1InteropHandler, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @dev MessageRoot smart contract that is used to prove message inclusion.
    IMessageRootBase public immutable MESSAGE_ROOT;

    /// @dev Address of the L1 asset router that finalizations are dispatched to.
    IL1AssetRouter public l1AssetRouter;

    /// @dev Address of the L1 nullifier, the only contract allowed to record the transient settlement layer
    /// for its failed-deposit recovery flow.
    address public l1Nullifier;

    /// @dev Tracks the processing status of L2 to L1 messages, indicating whether a message has already been finalized.
    mapping(uint256 chainId => mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)))
        public isWithdrawalFinalized;

    /// @notice Checks that the message sender is the L1 nullifier.
    modifier onlyNullifier() {
        require(msg.sender == l1Nullifier, Unauthorized(msg.sender));
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IMessageRootBase _messageRoot) reentrancyGuardInitializer {
        _disableInitializers();
        MESSAGE_ROOT = _messageRoot;
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy.
    /// @param _owner The address which can upgrade the contract and configure its dependencies.
    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        _transferOwnership(_owner);
    }

    /// @notice Sets the L1 asset router contract address.
    /// @dev Should be called only once by the owner.
    /// @param _l1AssetRouter The address of the asset router.
    function setL1AssetRouter(address _l1AssetRouter) external onlyOwner {
        require(address(l1AssetRouter) == address(0), AddressAlreadySet(address(l1AssetRouter)));
        require(_l1AssetRouter != address(0), ZeroAddress());
        l1AssetRouter = IL1AssetRouter(_l1AssetRouter);
    }

    /// @notice Sets the L1 nullifier contract address.
    /// @dev Should be called only once by the owner.
    /// @param _l1Nullifier The address of the nullifier.
    function setL1Nullifier(address _l1Nullifier) external onlyOwner {
        require(l1Nullifier == address(0), AddressAlreadySet(l1Nullifier));
        require(_l1Nullifier != address(0), ZeroAddress());
        l1Nullifier = _l1Nullifier;
    }

    /// @notice Finalize the withdrawal and release funds.
    /// @param _finalizeWithdrawalParams The structure that holds all necessary data to finalize withdrawal
    function finalizeDeposit(FinalizeL1DepositParams memory _finalizeWithdrawalParams) public {
        _finalizeDeposit(_finalizeWithdrawalParams);
    }

    /// @notice Internal function that handles the logic for finalizing withdrawals.
    /// @param _finalizeWithdrawalParams The structure that holds all necessary data to finalize withdrawal
    function _finalizeDeposit(
        FinalizeL1DepositParams memory _finalizeWithdrawalParams
    ) internal nonReentrant whenNotPaused {
        uint256 chainId = _finalizeWithdrawalParams.chainId;
        uint256 l2BatchNumber = _finalizeWithdrawalParams.l2BatchNumber;
        uint256 l2MessageIndex = _finalizeWithdrawalParams.l2MessageIndex;
        require(!isWithdrawalFinalized[chainId][l2BatchNumber][l2MessageIndex], WithdrawalAlreadyFinalized());
        isWithdrawalFinalized[chainId][l2BatchNumber][l2MessageIndex] = true;

        (bytes32 assetId, bytes memory transferData) = _verifyWithdrawal(_finalizeWithdrawalParams);

        AssetRouterBase(address(l1AssetRouter)).finalizeDeposit(chainId, assetId, transferData);
    }

    /// @notice Verifies the validity of a withdrawal message from L2 and returns withdrawal details.
    /// @param _finalizeWithdrawalParams The structure that holds all necessary data to finalize withdrawal
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdrawal.
    function _verifyWithdrawal(
        FinalizeL1DepositParams memory _finalizeWithdrawalParams
    ) internal returns (bytes32 assetId, bytes memory transferData) {
        (assetId, transferData) = _parseL2WithdrawalMessage(
            _finalizeWithdrawalParams.chainId,
            _finalizeWithdrawalParams.message
        );
        L2Message memory l2ToL1Message;
        {
            address l2Sender = _finalizeWithdrawalParams.l2Sender;
            // All withdrawals are emitted by the L2 InteropCenter (which wraps the asset-router
            // call in a single-call bundle). The bundle itself additionally authenticates that the inner
            // call originated from the L2 asset router (see `DataEncoding.parseInteropWithdrawalBundle`).
            require(l2Sender == L2_INTEROP_CENTER_ADDR, WrongL2Sender(l2Sender));

            l2ToL1Message = L2Message({
                txNumberInBatch: _finalizeWithdrawalParams.l2TxNumberInBatch,
                sender: l2Sender,
                data: _finalizeWithdrawalParams.message
            });
        }

        bool success = MESSAGE_ROOT.proveL2MessageInclusionShared({
            _chainId: _finalizeWithdrawalParams.chainId,
            _blockOrBatchNumber: _finalizeWithdrawalParams.l2BatchNumber,
            _index: _finalizeWithdrawalParams.l2MessageIndex,
            _message: l2ToL1Message,
            _proof: _finalizeWithdrawalParams.merkleProof
        });
        // withdrawal wrong proof
        require(success, InvalidProof());

        bytes32 leaf = MessageHashing.getLeafHashFromMessage(l2ToL1Message);
        ProofData memory proofData = MESSAGE_ROOT.getProofData({
            _chainId: _finalizeWithdrawalParams.chainId,
            _batchNumber: _finalizeWithdrawalParams.l2BatchNumber,
            _leafProofMask: _finalizeWithdrawalParams.l2MessageIndex,
            _leaf: leaf,
            _proof: _finalizeWithdrawalParams.merkleProof
        });
        _setTransientSettlementLayer(proofData.settlementLayerChainId, _finalizeWithdrawalParams.l2BatchNumber);
    }

    /// @inheritdoc IL1InteropHandler
    function setTransientSettlementLayer(
        uint256 _settlementLayerChainId,
        uint256 _l2BatchNumber
    ) external onlyNullifier {
        _setTransientSettlementLayer(_settlementLayerChainId, _l2BatchNumber);
    }

    /// @notice Records the settlement layer that processed the current proof in transient storage.
    /// @dev The value is consumed within the same transaction by the `L1AssetTracker` and cleared afterwards.
    function _setTransientSettlementLayer(uint256 _settlementLayerChainId, uint256 _l2BatchNumber) internal {
        TransientPrimitivesLib.set(TRANSIENT_SETTLEMENT_LAYER_SLOT, _settlementLayerChainId);
        TransientPrimitivesLib.set(TRANSIENT_SETTLEMENT_LAYER_SLOT + 1, _l2BatchNumber);
        emit TransientSettlementLayerSet(_settlementLayerChainId);
    }

    /// @inheritdoc IL1InteropHandler
    function getTransientSettlementLayer() external view returns (uint256, uint256) {
        return (
            TransientPrimitivesLib.getUint256(TRANSIENT_SETTLEMENT_LAYER_SLOT),
            TransientPrimitivesLib.getUint256(TRANSIENT_SETTLEMENT_LAYER_SLOT + 1)
        );
    }

    /// @notice Parses the withdrawal message and returns withdrawal details.
    /// @dev All withdrawals are routed through the L2 InteropCenter: the message is a single-call
    /// @dev interop bundle wrapping an L2-asset-router `finalizeDeposit` call destined for L1.
    /// @param _chainId The ZK chain ID.
    /// @param _l2ToL1message The encoded L2 -> L1 message.
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdrawal.
    /// @dev The `transferData` is expected to be encoded using `DataEncoding.encodeBridgeMintData`.
    /// Note, that the `_originalCaller`, `_originToken` and `_erc20Metadata` fields in the encoded `transferData` could be empty,
    /// so they should not be relied upon.
    function _parseL2WithdrawalMessage(
        uint256 _chainId,
        bytes memory _l2ToL1message
    ) internal view returns (bytes32 assetId, bytes memory transferData) {
        // All withdrawals (base token and ERC20) arrive as a single-call InteropBundle prefixed with
        // BUNDLE_IDENTIFIER, emitted by the L2 InteropCenter; raw asset-router messages are not accepted.
        require(_l2ToL1message.length > 0, WrongMsgLength(1, 0));
        require(_l2ToL1message[0] == BUNDLE_IDENTIFIER, InvalidSelector(DataEncoding.getSelector(_l2ToL1message)));
        // slither-disable-next-line unused-return
        return DataEncoding.parseInteropWithdrawalBundle(_chainId, _l2ToL1message, address(l1AssetRouter));
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
