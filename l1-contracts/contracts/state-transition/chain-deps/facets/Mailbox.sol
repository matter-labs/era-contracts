// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IMailbox} from "../../chain-interfaces/IMailbox.sol";
import {ISelfDescribingFacet} from "../../chain-interfaces/ISelfDescribingFacet.sol";
import {IMailboxImpl} from "../../chain-interfaces/IMailboxImpl.sol";
import {IInteropCenter} from "../../../interop/IInteropCenter.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";

import {ITransactionFilterer} from "../../chain-interfaces/ITransactionFilterer.sol";
import {IEIP7702Checker} from "../../chain-interfaces/IEIP7702Checker.sol";
import {PriorityTree} from "../../libraries/PriorityTree.sol";
import {TransactionValidator} from "../../libraries/TransactionValidator.sol";
import {
    BridgehubL2TransactionRequest,
    L2CanonicalTransaction,
    L2Log,
    L2Message,
    TxStatus,
    WritePriorityOpParams
} from "../../../common/Messaging.sol";
import {MessageHashing} from "../../../common/libraries/MessageHashing.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {L2ContractHelper} from "../../../common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "../../../vendor/AddressAliasHelper.sol";
import {ZKChainBase} from "./ZKChainBase.sol";
import {
    MAX_NEW_FACTORY_DEPS,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    SERVICE_TRANSACTION_SENDER,
    SETTLEMENT_LAYER_RELAY_SENDER,
    PAUSE_DEPOSITS_TIME_WINDOW_START_TESTNET,
    PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET
} from "../../../common/Config.sol";
import {L2_INTEROP_CENTER_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {IAssetRouterShared} from "../../../bridge/asset-router/IAssetRouterShared.sol";
import {
    AddressNotZero,
    GasPerPubdataMismatch,
    InvalidChainId,
    MsgValueTooLow,
    NotAssetRouter,
    OnlyEraSupported,
    TooManyFactoryDeps,
    TransactionNotAllowed,
    ValueMismatch,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {DepositsPaused, NotL1, NotSettlementLayer, NotZKChain} from "../../L1StateTransitionErrors.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";
import {IMessageVerification, MessageVerification} from "../../../common/MessageVerification.sol";
import {OnlyGateway} from "../../../core/bridgehub/L1BridgehubErrors.sol";
import {IL1ChainAssetHandler} from "../../../core/chain-asset-handler/IL1ChainAssetHandler.sol";

/// @title ZKsync Mailbox contract providing interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract MailboxFacet is ZKChainBase, IMailboxImpl, MessageVerification, ISelfDescribingFacet {
    using UncheckedMath for uint256;
    using PriorityTree for PriorityTree.Tree;

    /// @inheritdoc IZKChainBase
    // solhint-disable-next-line const-name-snakecase
    string public constant override getName = "MailboxFacet";

    /// @dev Deployed utility contract to check that account is EIP7702 one
    IEIP7702Checker internal immutable EIP_7702_CHECKER;

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 internal immutable L1_CHAIN_ID;

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID; // TODO(EVM-1216): remove after the legacy mailbox.finalizeEthWithdrawal and mailbox.requestL2Transaction are deprecated.

    /// @dev The address of the L1ChainAssetHandler system contract. Only used on L1.
    address internal immutable CHAIN_ASSET_HANDLER;

    uint256 internal immutable PAUSE_DEPOSITS_TIME_WINDOW_START;

    modifier onlyL1() {
        if (block.chainid != L1_CHAIN_ID) {
            revert NotL1(block.chainid);
        }
        _;
    }

    modifier onlyGateway() {
        if (block.chainid == L1_CHAIN_ID) {
            revert OnlyGateway();
        }
        _;
    }

    constructor(
        uint256 _eraChainId,
        uint256 _l1ChainId,
        address _chainAssetHandler,
        IEIP7702Checker _eip7702Checker,
        bool _isTestnet
    ) {
        if (address(_eip7702Checker) == address(0) && block.chainid == _l1ChainId) {
            revert ZeroAddress();
        } else if (address(_eip7702Checker) != address(0) && block.chainid != _l1ChainId) {
            revert AddressNotZero();
        }
        ERA_CHAIN_ID = _eraChainId; // TODO(EVM-1216): remove after the legacy mailbox.finalizeEthWithdrawal and mailbox.requestL2Transaction are deprecated.
        L1_CHAIN_ID = _l1ChainId;
        CHAIN_ASSET_HANDLER = _chainAssetHandler;
        EIP_7702_CHECKER = _eip7702Checker;

        PAUSE_DEPOSITS_TIME_WINDOW_START = _isTestnet
            ? PAUSE_DEPOSITS_TIME_WINDOW_START_TESTNET
            : PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET;
    }

    /// @inheritdoc IMailboxImpl
    function bridgehubRequestL2Transaction(
        BridgehubL2TransactionRequest calldata _request
    ) external onlyBridgehub returns (bytes32 canonicalTxHash) {
        canonicalTxHash = _requestL2TransactionSender(_request);
    }

    /// @inheritdoc IMessageVerification
    function proveL2MessageInclusionShared(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) public view override returns (bool) {
        if (s.chainId != _chainId) {
            revert InvalidChainId();
        }
        return
            super.proveL2MessageInclusionShared({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _index: _index,
                _message: _message,
                _proof: _proof
            });
    }

    /// @inheritdoc IMailboxImpl
    function proveL2MessageInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) public view returns (bool) {
        return
            _proveL2LogInclusion({
                _chainId: s.chainId,
                _blockOrBatchNumber: _batchNumber,
                _index: _index,
                _log: MessageHashing._l2MessageToLog(_message),
                _proof: _proof
            });
    }

    /// @inheritdoc IMessageVerification
    function proveL2LogInclusionShared(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _index,
        L2Log calldata _log,
        bytes32[] calldata _proof
    ) public view override returns (bool) {
        if (s.chainId != _chainId) {
            revert InvalidChainId();
        }
        return
            super.proveL2LogInclusionShared({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _index: _index,
                _log: _log,
                _proof: _proof
            });
    }

    /// @inheritdoc IMailboxImpl
    function proveL2LogInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Log calldata _log,
        bytes32[] calldata _proof
    ) external view returns (bool) {
        return
            _proveL2LogInclusion({
                _chainId: s.chainId,
                _blockOrBatchNumber: _batchNumber,
                _index: _index,
                _log: _log,
                _proof: _proof
            });
    }

    /// @inheritdoc IMailboxImpl
    function proveL1ToL2TransactionStatus(
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) public view returns (bool) {
        return
            proveL1ToL2TransactionStatusShared({
                _chainId: s.chainId,
                _l2TxHash: _l2TxHash,
                _l2BatchNumber: _l2BatchNumber,
                _l2MessageIndex: _l2MessageIndex,
                _l2TxNumberInBatch: _l2TxNumberInBatch,
                _merkleProof: _merkleProof,
                _status: _status
            });
    }

    /// @inheritdoc IMessageVerification
    function proveL2LeafInclusionShared(
        uint256 _chainId,
        uint256 _blockOrBatchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) public view virtual override returns (bool) {
        if (s.chainId != _chainId) {
            revert InvalidChainId();
        }
        return
            super.proveL2LeafInclusionShared({
                _chainId: _chainId,
                _blockOrBatchNumber: _blockOrBatchNumber,
                _leafProofMask: _leafProofMask,
                _leaf: _leaf,
                _proof: _proof
            });
    }

    /// @inheritdoc IMailboxImpl
    function proveL2LeafInclusion(
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) external view returns (bool) {
        return
            _proveL2LeafInclusion({
                _chainId: s.chainId,
                _blockOrBatchNumber: _batchNumber,
                _leafProofMask: _leafProofMask,
                _leaf: _leaf,
                _proof: _proof
            });
    }

    function _proveL2LeafInclusionRecursive(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof,
        uint256 _depth
    ) internal view override returns (bool) {
        // No gas optimization here as the usage of the method is discouraged and the Bridgehub one should be used.
        return
            MessageVerification(address(IBridgehubBase(s.bridgehub).messageRoot()))
                .proveL2LeafInclusionSharedRecursive({
                    _chainId: _chainId,
                    _blockOrBatchNumber: _batchNumber,
                    _leafProofMask: _leafProofMask,
                    _leaf: _leaf,
                    _proof: _proof,
                    _depth: _depth
                });
    }

    /// @inheritdoc IMailboxImpl
    function l2TransactionBaseCost(
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) public view returns (uint256) {
        uint256 l2GasPrice = _deriveL2GasPrice(_gasPrice, _l2GasPerPubdataByteLimit);
        return l2GasPrice * _l2GasLimit;
    }

    /// @inheritdoc IMailboxImpl
    // slither-disable-next-line reentrancy-no-eth
    function requestL2TransactionToGatewayMailbox(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) public override onlyL1 returns (bytes32 canonicalTxHash) {
        if (!IBridgehubBase(s.bridgehub).whitelistedSettlementLayers(s.chainId)) {
            revert NotSettlementLayer();
        }
        if (IBridgehubBase(s.bridgehub).getZKChain(_chainId) != msg.sender) {
            revert NotZKChain();
        }
        if (_expirationTimestamp != 0) {
            revert ValueMismatch(0, _expirationTimestamp);
        }
        // Note during the upgrade to V31 no chain will be on GW.

        BridgehubL2TransactionRequest memory wrappedRequest = _wrapRequest({
            _chainId: _chainId,
            _canonicalTxHash: _canonicalTxHash,
            _expirationTimestamp: _expirationTimestamp
        });
        canonicalTxHash = _requestL2TransactionFree(wrappedRequest);
    }

    /// @inheritdoc IMailboxImpl
    function bridgehubRequestL2TransactionOnGateway(
        bytes32 _canonicalTxHash,
        uint64
    ) external override onlyBridgehubOrInteropCenter {
        _writePriorityOpHash(_canonicalTxHash);
        emit NewRelayedPriorityTransaction(_getTotalPriorityTxs(), _canonicalTxHash, 0);
        emit NewPriorityRequestId(_getTotalPriorityTxs(), _canonicalTxHash);
    }

    function _wrapRequest(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) internal pure returns (BridgehubL2TransactionRequest memory) {
        // solhint-disable-next-line func-named-parameters
        bytes memory data = abi.encodeCall(
            IInteropCenter.forwardTransactionOnGateway,
            (_chainId, _canonicalTxHash, _expirationTimestamp)
        );
        return
            BridgehubL2TransactionRequest({
                /// There is no sender for the wrapping, we use a virtual address.
                sender: SETTLEMENT_LAYER_RELAY_SENDER,
                contractL2: L2_INTEROP_CENTER_ADDR,
                mintValue: 0,
                l2Value: 0,
                // Very large amount
                l2GasLimit: 72_000_000,
                l2Calldata: data,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                factoryDeps: new bytes[](0),
                // Tx is free, no so refund recipient needed
                refundRecipient: address(0)
            });
    }

    /// @inheritdoc IMailboxImpl
    function requestL2ServiceTransaction(
        address _contractL2,
        bytes calldata _l2Calldata
    ) external onlyServiceTransaction onlyL1 returns (bytes32 canonicalTxHash) {
        canonicalTxHash = _requestL2TransactionFree(
            BridgehubL2TransactionRequest({
                sender: SERVICE_TRANSACTION_SENDER,
                contractL2: _contractL2,
                mintValue: 0,
                l2Value: 0,
                // Very large amount
                l2GasLimit: 72_000_000,
                l2Calldata: _l2Calldata,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                factoryDeps: new bytes[](0),
                // Tx is free, so no refund recipient needed
                refundRecipient: address(0)
            })
        );

        if (s.settlementLayer != address(0)) {
            // slither-disable-next-line unused-return
            IMailbox(s.settlementLayer).requestL2TransactionToGatewayMailbox({
                _chainId: s.chainId,
                _canonicalTxHash: canonicalTxHash,
                _expirationTimestamp: 0
            });
        }
    }

    function _requestL2TransactionSender(
        BridgehubL2TransactionRequest memory _request
    ) internal nonReentrant returns (bytes32 canonicalTxHash) {
        // Check that the transaction is allowed by the filterer (if the filterer is set).
        if (s.transactionFilterer != address(0)) {
            if (
                !ITransactionFilterer(s.transactionFilterer).isTransactionAllowed({
                    sender: _request.sender,
                    contractL2: _request.contractL2,
                    mintValue: _request.mintValue,
                    l2Value: _request.l2Value,
                    l2Calldata: _request.l2Calldata,
                    refundRecipient: _request.refundRecipient
                })
            ) {
                revert TransactionNotAllowed();
            }
        }

        // Enforcing that `_request.l2GasPerPubdataByteLimit` equals to a certain constant number. This is needed
        // to ensure that users do not get used to using "exotic" numbers for _request.l2GasPerPubdataByteLimit, e.g. 1-2, etc.
        // VERY IMPORTANT: nobody should rely on this constant to be fixed and every contract should give their users the ability to provide the
        // ability to provide `_request.l2GasPerPubdataByteLimit` for each independent transaction.
        // CHANGING THIS CONSTANT SHOULD BE A CLIENT-SIDE CHANGE.
        if (_request.l2GasPerPubdataByteLimit != REQUIRED_L2_GAS_PRICE_PER_PUBDATA) {
            revert GasPerPubdataMismatch();
        }

        WritePriorityOpParams memory params;
        params.request = _request;

        canonicalTxHash = _requestL2Transaction(params);
    }

    function _requestL2Transaction(WritePriorityOpParams memory _params) internal returns (bytes32 canonicalTxHash) {
        BridgehubL2TransactionRequest memory request = _params.request;

        // For ZKsync OS factory deps will be ignored
        if (request.factoryDeps.length > MAX_NEW_FACTORY_DEPS) {
            revert TooManyFactoryDeps();
        }
        _params.txId = _nextPriorityTxId();

        // Checking that the user provided enough ether to pay for the transaction.
        _params.l2GasPrice = _deriveL2GasPrice(tx.gasprice, request.l2GasPerPubdataByteLimit);
        uint256 baseCost = _params.l2GasPrice * request.l2GasLimit;
        // User must pay the base cost for the L1 -> L2 transaction.
        // L2 msg.value can be anything, but if it’s too low the tx will fail.
        if (request.mintValue < baseCost) {
            revert MsgValueTooLow(baseCost, request.mintValue);
        }

        bool is7702AccountRefundRecipient = false;
        bool is7702AccountSender = false;

        if (block.chainid == L1_CHAIN_ID) {
            is7702AccountRefundRecipient = EIP_7702_CHECKER.isEIP7702Account(request.refundRecipient);
            is7702AccountSender = EIP_7702_CHECKER.isEIP7702Account(request.sender); // This is not the same as refundRecipient, as it appears to be the AR during TwoBridges.
        }

        request.refundRecipient = AddressAliasHelper.actualRefundRecipientMailbox(
            request.refundRecipient,
            request.sender,
            is7702AccountRefundRecipient,
            is7702AccountSender
        );
        // Change the sender address if it is a smart contract to prevent address collision between L1 and L2.
        // Please note, currently ZKsync address derivation is different from Ethereum one, but it may be changed in the future.
        // solhint-disable avoid-tx-origin
        // slither-disable-next-line tx-origin
        if (request.sender != tx.origin && !is7702AccountSender) {
            request.sender = AddressAliasHelper.applyL1ToL2Alias(request.sender);
        }
        L2CanonicalTransaction memory transaction;
        (transaction, canonicalTxHash) = _validateTx(_params);

        _writePriorityOp(transaction, _params.request.factoryDeps, canonicalTxHash);
        if (s.settlementLayer != address(0)) {
            // slither-disable-next-line unused-return
            IMailbox(s.settlementLayer).requestL2TransactionToGatewayMailbox({
                _chainId: s.chainId,
                _canonicalTxHash: canonicalTxHash,
                _expirationTimestamp: 0
            });
        }
    }

    function _nextPriorityTxId() internal view returns (uint256) {
        return s.priorityTree.getTotalPriorityTxs();
    }

    function _requestL2TransactionFree(
        BridgehubL2TransactionRequest memory _request
    ) internal nonReentrant returns (bytes32 canonicalTxHash) {
        WritePriorityOpParams memory params = WritePriorityOpParams({
            request: _request,
            txId: _nextPriorityTxId(),
            l2GasPrice: 0
        });

        L2CanonicalTransaction memory transaction;
        (transaction, canonicalTxHash) = _validateTx(params);
        _writePriorityOp(transaction, params.request.factoryDeps, canonicalTxHash);
    }

    function _serializeL2Transaction(
        WritePriorityOpParams memory _priorityOpParams
    ) internal view returns (L2CanonicalTransaction memory transaction) {
        BridgehubL2TransactionRequest memory request = _priorityOpParams.request;
        transaction = L2CanonicalTransaction({
            txType: _getPriorityTxType(),
            from: uint256(uint160(request.sender)),
            to: uint256(uint160(request.contractL2)),
            gasLimit: request.l2GasLimit,
            gasPerPubdataByteLimit: request.l2GasPerPubdataByteLimit,
            maxFeePerGas: uint256(_priorityOpParams.l2GasPrice),
            maxPriorityFeePerGas: uint256(0),
            paymaster: uint256(0),
            // Note, that the priority operation id is used as "nonce" for L1->L2 transactions
            nonce: uint256(_priorityOpParams.txId),
            value: request.l2Value,
            reserved: [request.mintValue, uint256(uint160(request.refundRecipient)), 0, 0],
            data: request.l2Calldata,
            signature: new bytes(0),
            factoryDeps: L2ContractHelper.hashFactoryDeps(request.factoryDeps),
            paymasterInput: new bytes(0),
            reservedDynamic: new bytes(0)
        });
    }

    function _validateTx(
        WritePriorityOpParams memory _priorityOpParams
    ) internal view returns (L2CanonicalTransaction memory transaction, bytes32 canonicalTxHash) {
        transaction = _serializeL2Transaction(_priorityOpParams);
        bytes memory transactionEncoding = abi.encode(transaction);
        // solhint-disable-next-line func-named-parameters
        TransactionValidator.validateL1ToL2Transaction(
            transaction,
            transactionEncoding,
            s.priorityTxMaxGasLimit,
            s.feeParams.priorityTxMaxPubdata,
            s.zksyncOS
        );
        canonicalTxHash = keccak256(transactionEncoding);
    }

    /// @notice Deposits are paused when a chain migrates to/from GW.
    function depositsPaused() public view returns (bool) {
        return
            _isInDepositsPausedWindow(PAUSE_DEPOSITS_TIME_WINDOW_START) ||
            (block.chainid == L1_CHAIN_ID &&
                IL1ChainAssetHandler(CHAIN_ASSET_HANDLER).isMigrationInProgress(s.chainId));
    }

    /// @notice Stores a transaction record in storage & send event about that
    function _writePriorityOp(
        L2CanonicalTransaction memory _transaction,
        bytes[] memory _factoryDeps,
        bytes32 _canonicalTxHash
    ) internal {
        _writePriorityOpHash(_canonicalTxHash);

        /// We only check deposits paused on L1 to keep the GW and L1 Priority queues the same.
        if (block.chainid == L1_CHAIN_ID) {
            require(!depositsPaused(), DepositsPaused());
        }

        // Data that is needed for the operator to simulate priority queue offchain
        // solhint-disable-next-line func-named-parameters
        emit NewPriorityRequest(_transaction.nonce, _canonicalTxHash, 0, _transaction, _factoryDeps);
        emit NewPriorityRequestId(_transaction.nonce, _canonicalTxHash);
    }

    // solhint-disable-next-line no-unused-vars
    function _writePriorityOpHash(bytes32 _canonicalTxHash) internal {
        s.priorityTree.push(_canonicalTxHash);
        uint256 totalPriorityTxs = s.priorityTree.getTotalPriorityTxs();
        uint256 newRequestId = totalPriorityTxs - 1;
        s.priorityOpsRequestTimestamp[newRequestId] = block.timestamp;
    }

    ///////////////////////////////////////////////////////
    //////// Legacy Era functions

    /// @inheritdoc IMailboxImpl
    /// @dev Deprecated stub. The L2->L1 base-token withdrawal message is still tagged with the
    /// `finalizeEthWithdrawal` selector, so the selector must remain part of the facet's ABI even though funds
    /// are now finalized through the asset-router / L1Nullifier path. The entry point itself always reverts;
    /// full removal is tracked separately (EVM-1216).
    function finalizeEthWithdrawal(uint256, uint256, uint16, bytes calldata, bytes32[] calldata) external onlyL1 {
        revert TransactionNotAllowed();
    }

    /// @inheritdoc IMailboxImpl
    function requestL2Transaction(
        // TODO(EVM-1216): remove after the legacy mailbox.finalizeEthWithdrawal and mailbox.requestL2Transaction are deprecated.
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) external payable onlyL1 returns (bytes32 canonicalTxHash) {
        if (s.chainId != ERA_CHAIN_ID) {
            revert OnlyEraSupported();
        }
        address assetRouter = address(IBridgehubBase(s.bridgehub).assetRouter());
        require(msg.sender != assetRouter, NotAssetRouter(msg.sender, assetRouter));
        canonicalTxHash = _requestL2TransactionSender(
            BridgehubL2TransactionRequest({
                sender: msg.sender,
                contractL2: _contractL2,
                mintValue: msg.value,
                l2Value: _l2Value,
                l2GasLimit: _l2GasLimit,
                l2Calldata: _calldata,
                l2GasPerPubdataByteLimit: _l2GasPerPubdataByteLimit,
                factoryDeps: _factoryDeps,
                refundRecipient: _refundRecipient
            })
        );
        address sharedBridge = address(IBridgehubBase(s.bridgehub).assetRouter());
        IAssetRouterShared(sharedBridge).bridgehubDepositBaseToken{value: msg.value}(
            s.chainId,
            s.baseTokenAssetId,
            msg.sender,
            msg.value
        );
    }

    /// @inheritdoc ISelfDescribingFacet
    /// @dev Packed list (4 bytes per selector) generated from this facet's ABI — every externally
    ///      served function except the unregistered helper views `getName()` and `selectors()`
    ///      (see `Utils.getAllSelectors`). Guarded against drift by FacetSelfDescription.t.sol.
    ///      0x12f43dab bridgehubRequestL2Transaction((address,address,uint256,uint256,bytes,uint256,uint256,bytes[],address))
    ///      0xddcc9eec bridgehubRequestL2TransactionOnGateway(bytes32,uint64)
    ///      0x60da3e83 depositsPaused()
    ///      0x6c0960f9 finalizeEthWithdrawal(uint256,uint256,uint16,bytes,bytes32[])
    ///      0xb473318e l2TransactionBaseCost(uint256,uint256,uint256)
    ///      0x685143b9 proveL1DepositParamsInclusion((uint256,uint256,uint256,address,uint16,bytes,bytes32[]))
    ///      0x042901c7 proveL1ToL2TransactionStatus(bytes32,uint256,uint256,uint16,bytes32[],uint8)
    ///      0xda24b3ee proveL1ToL2TransactionStatusShared(uint256,bytes32,uint256,uint256,uint16,bytes32[],uint8)
    ///      0x7efda2ae proveL2LeafInclusion(uint256,uint256,bytes32,bytes32[])
    ///      0x79cf6165 proveL2LeafInclusionShared(uint256,uint256,uint256,bytes32,bytes32[])
    ///      0x353d7128 proveL2LeafInclusionSharedRecursive(uint256,uint256,uint256,bytes32,bytes32[],uint256)
    ///      0x263b7f8e proveL2LogInclusion(uint256,uint256,(uint8,bool,uint16,address,bytes32,bytes32),bytes32[])
    ///      0xe896760d proveL2LogInclusionShared(uint256,uint256,uint256,(uint8,bool,uint16,address,bytes32,bytes32),bytes32[])
    ///      0xe4948f43 proveL2MessageInclusion(uint256,uint256,(uint16,address,bytes),bytes32[])
    ///      0x18b7fc22 proveL2MessageInclusionShared(uint256,uint256,uint256,(uint16,address,bytes),bytes32[])
    ///      0xd07b90d1 requestL2ServiceTransaction(address,bytes)
    ///      0xeb672419 requestL2Transaction(address,uint256,bytes,uint256,uint256,bytes[],address)
    ///      0xd0772551 requestL2TransactionToGatewayMailbox(uint256,bytes32,uint64)
    function selectors() public pure returns (bytes4[] memory result) {
        bytes
            memory packed = hex"12f43dabddcc9eec60da3e836c0960f9b473318e685143b9042901c7da24b3ee7efda2ae79cf6165353d7128263b7f8ee896760de4948f4318b7fc22d07b90d1eb672419d0772551";
        uint256 count = packed.length / 4;
        result = new bytes4[](count);
        for (uint256 i = 0; i < count; ++i) {
            bytes4 selector;
            assembly {
                selector := mload(add(add(packed, 0x20), mul(i, 4)))
            }
            result[i] = selector;
        }
    }
}
