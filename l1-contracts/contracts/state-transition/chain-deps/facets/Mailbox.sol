// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts-v4/utils/math/Math.sol";

import {IMailbox} from "../../chain-interfaces/IMailbox.sol";
import {IMailboxImpl} from "../../chain-interfaces/IMailboxImpl.sol";
import {IChainTypeManager} from "../../IChainTypeManager.sol";
import {IBridgehub} from "../../../bridgehub/IBridgehub.sol";
import {IInteropCenter} from "../../../interop/IInteropCenter.sol";

import {ITransactionFilterer} from "../../chain-interfaces/ITransactionFilterer.sol";
import {PriorityTree} from "../../libraries/PriorityTree.sol";
import {TransactionValidator} from "../../libraries/TransactionValidator.sol";
import {BridgehubL2TransactionRequest, L2CanonicalTransaction, L2Log, L2Message, TxStatus, WritePriorityOpParams} from "../../../common/Messaging.sol";
import {MessageHashing, ProofData} from "../../../common/libraries/MessageHashing.sol";
import {FeeParams, PubdataPricingMode} from "../ZKChainStorage.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {L2ContractHelper} from "../../../common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "../../../vendor/AddressAliasHelper.sol";
import {ZKChainBase} from "./ZKChainBase.sol";
import {L1_GAS_PER_PUBDATA_BYTE, MAX_NEW_FACTORY_DEPS, PRIORITY_EXPIRATION, PRIORITY_OPERATION_L2_TX_TYPE, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, SERVICE_TRANSACTION_SENDER, SETTLEMENT_LAYER_RELAY_SENDER} from "../../../common/Config.sol";
import {L2_INTEROP_CENTER_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";

import {IL1AssetRouter} from "../../../bridge/asset-router/IL1AssetRouter.sol";

import {BaseTokenGasPriceDenominatorNotSet, BatchNotExecuted, GasPerPubdataMismatch, InvalidChainId, MsgValueTooLow, OnlyEraSupported, TooManyFactoryDeps, TransactionNotAllowed} from "../../../common/L1ContractErrors.sol";
import {LocalRootIsZero, LocalRootMustBeZero, NotHyperchain, NotL1, NotSettlementLayer} from "../../L1StateTransitionErrors.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";
import {IMessageVerification, MessageVerification} from "../../../common/MessageVerification.sol";
import {IL1AssetTracker} from "../../../bridge/asset-tracker/IL1AssetTracker.sol";
import {BALANCE_CHANGE_VERSION} from "../../../bridge/asset-tracker/IAssetTrackerBase.sol";
import {BalanceChange} from "../../../common/Messaging.sol";
import {INativeTokenVault} from "../../../bridge/ntv/INativeTokenVault.sol";
import {IBridgedStandardToken} from "../../../bridge/BridgedStandardERC20.sol";

/// @title ZKsync Mailbox contract providing interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract MailboxFacet is ZKChainBase, IMailboxImpl, MessageVerification {
    using UncheckedMath for uint256;
    using PriorityTree for PriorityTree.Tree;

    /// @inheritdoc IZKChainBase
    string public constant override getName = "MailboxFacet";

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID;

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 internal immutable L1_CHAIN_ID;

    modifier onlyL1() {
        if (block.chainid != L1_CHAIN_ID) {
            revert NotL1(block.chainid);
        }
        _;
    }

    constructor(uint256 _eraChainId, uint256 _l1ChainId) {
        ERA_CHAIN_ID = _eraChainId;
        L1_CHAIN_ID = _l1ChainId;
    }

    /// @inheritdoc IMailboxImpl
    function bridgehubRequestL2Transaction(
        BridgehubL2TransactionRequest calldata _request
    ) external onlyBridgehubOrInteropCenter returns (bytes32 canonicalTxHash) {
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
                _batchNumber: _batchNumber,
                _leafProofMask: _leafProofMask,
                _leaf: _leaf,
                _proof: _proof
            });
    }

    function _proveL2LeafInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) internal view override returns (bool) {
        ProofData memory proofData = MessageHashing._getProofData({
            _chainId: _chainId,
            _batchNumber: _batchNumber,
            _leafProofMask: _leafProofMask,
            _leaf: _leaf,
            _proof: _proof
        });

        // If the `finalProofNode` is true, then we assume that this is L1 contract of the top-level
        // in the aggregation, i.e. the batch root is stored here on L1.
        if (proofData.finalProofNode) {
            // Double checking that the batch has been executed.
            if (_batchNumber > s.totalBatchesExecuted) {
                revert BatchNotExecuted(_batchNumber);
            }

            bytes32 correctBatchRoot = s.l2LogsRootHashes[_batchNumber];
            if (correctBatchRoot == bytes32(0)) {
                revert LocalRootIsZero();
            }
            return correctBatchRoot == proofData.batchSettlementRoot;
        }

        if (s.l2LogsRootHashes[_batchNumber] != bytes32(0)) {
            revert LocalRootMustBeZero();
        }
        // Assuming that `settlementLayerChainId` is an honest chain, the `chainIdLeaf` should belong
        // to a chain's message root only if the chain has indeed executed its batch on top of it.
        //
        // We trust all chains whitelisted by the Bridgehub governance.
        if (!IBridgehub(s.bridgehub).whitelistedSettlementLayers(proofData.settlementLayerChainId)) {
            revert NotSettlementLayer();
        }
        address settlementLayerAddress = IBridgehub(s.bridgehub).getZKChain(proofData.settlementLayerChainId);

        return
            IMailbox(settlementLayerAddress).proveL2LeafInclusion(
                proofData.settlementLayerBatchNumber,
                proofData.settlementLayerBatchRootMask,
                proofData.chainIdLeaf,
                MessageHashing.extractSliceUntilEnd(_proof, proofData.ptr)
            );
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

    /// @notice Derives the price for L2 gas in base token to be paid.
    /// @param _l1GasPrice The gas price on L1
    /// @param _gasPerPubdata The price for each pubdata byte in L2 gas
    /// @return The price of L2 gas in the base token
    function _deriveL2GasPrice(uint256 _l1GasPrice, uint256 _gasPerPubdata) internal view returns (uint256) {
        FeeParams memory feeParams = s.feeParams;
        if (s.baseTokenGasPriceMultiplierDenominator == 0) {
            revert BaseTokenGasPriceDenominatorNotSet();
        }
        uint256 l1GasPriceConverted = (_l1GasPrice * s.baseTokenGasPriceMultiplierNominator) /
            s.baseTokenGasPriceMultiplierDenominator;
        uint256 pubdataPriceBaseToken;
        if (feeParams.pubdataPricingMode == PubdataPricingMode.Rollup) {
            // slither-disable-next-line divide-before-multiply
            pubdataPriceBaseToken = L1_GAS_PER_PUBDATA_BYTE * l1GasPriceConverted;
        }

        // slither-disable-next-line divide-before-multiply
        uint256 batchOverheadBaseToken = uint256(feeParams.batchOverheadL1Gas) * l1GasPriceConverted;
        uint256 fullPubdataPriceBaseToken = pubdataPriceBaseToken +
            batchOverheadBaseToken /
            uint256(feeParams.maxPubdataPerBatch);

        uint256 l2GasPrice = feeParams.minimalL2GasPrice + batchOverheadBaseToken / uint256(feeParams.maxL2GasPerBatch);
        uint256 minL2GasPriceBaseToken = (fullPubdataPriceBaseToken + _gasPerPubdata - 1) / _gasPerPubdata;

        return Math.max(l2GasPrice, minL2GasPriceBaseToken);
    }

    /// @inheritdoc IMailboxImpl
    function requestL2TransactionToGatewayMailboxWithBalanceChange(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        uint256 _baseTokenAmount,
        bool _getBalanceChange
    ) external override onlyL1 returns (bytes32 canonicalTxHash) {
        if (!IBridgehub(s.bridgehub).whitelistedSettlementLayers(s.chainId)) {
            revert NotSettlementLayer();
        }
        if (IChainTypeManager(s.chainTypeManager).getZKChain(_chainId) != msg.sender) {
            revert NotHyperchain();
        }

        (bytes32 assetId, uint256 amount) = (bytes32(0), 0);
        BalanceChange memory balanceChange;
        /// baseTokenAssetId is set on Gateway.
        balanceChange.baseTokenAmount = _baseTokenAmount;

        if (_getBalanceChange) {
            IL1AssetTracker assetTracker = IL1AssetTracker(address(IInteropCenter(s.interopCenter).assetTracker()));
            INativeTokenVault nativeTokenVault = INativeTokenVault(
                IL1AssetRouter(IInteropCenter(s.interopCenter).assetRouter()).nativeTokenVault()
            );

            (assetId, amount) = (assetTracker.consumeBalanceChange(s.chainId, _chainId));
            uint256 tokenOriginChainId = nativeTokenVault.originChainId(assetId);
            address originToken;
            address tokenAddress = nativeTokenVault.tokenAddress(assetId);
            if (tokenOriginChainId == block.chainid) {
                originToken = tokenAddress;
            } else {
                originToken = IBridgedStandardToken(tokenAddress).originToken();
            }
            balanceChange = BalanceChange({
                version: BALANCE_CHANGE_VERSION,
                baseTokenAssetId: bytes32(0),
                baseTokenAmount: _baseTokenAmount,
                assetId: assetId,
                amount: amount,
                tokenOriginChainId: tokenOriginChainId,
                originToken: originToken
            });
        }

        BridgehubL2TransactionRequest memory wrappedRequest = _wrapRequest({
            _chainId: _chainId,
            _canonicalTxHash: _canonicalTxHash,
            _expirationTimestamp: _expirationTimestamp,
            _balanceChange: balanceChange
        });
        canonicalTxHash = _requestL2TransactionFree(wrappedRequest);
    }

    /// @inheritdoc IMailboxImpl
    function bridgehubRequestL2TransactionOnGateway(
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external override onlyBridgehubOrInteropCenter {
        _writePriorityOpHash(_canonicalTxHash, _expirationTimestamp);
        emit NewRelayedPriorityTransaction(_getTotalPriorityTxs(), _canonicalTxHash, _expirationTimestamp);
        emit NewPriorityRequestId(_getTotalPriorityTxs(), _canonicalTxHash);
    }

    function _wrapRequest(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp,
        BalanceChange memory _balanceChange
    ) internal view returns (BridgehubL2TransactionRequest memory) {
        // solhint-disable-next-line func-named-parameters
        bytes memory data = abi.encodeCall(
            IInteropCenter.forwardTransactionOnGatewayWithBalanceChange,
            (_chainId, _canonicalTxHash, _expirationTimestamp, _balanceChange)
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

    ///  @inheritdoc IMailboxImpl
    function requestL2ServiceTransaction(
        address _contractL2,
        bytes calldata _l2Calldata
    ) external onlyServiceTransaction returns (bytes32 canonicalTxHash) {
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
            IMailbox(s.settlementLayer).requestL2TransactionToGatewayMailboxWithBalanceChange({
                _chainId: s.chainId,
                _canonicalTxHash: canonicalTxHash,
                _expirationTimestamp: uint64(block.timestamp + PRIORITY_EXPIRATION),
                _baseTokenAmount: 0,
                _getBalanceChange: false
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

        if (request.factoryDeps.length > MAX_NEW_FACTORY_DEPS) {
            revert TooManyFactoryDeps();
        }
        _params.txId = _nextPriorityTxId();

        // Checking that the user provided enough ether to pay for the transaction.
        _params.l2GasPrice = _deriveL2GasPrice(tx.gasprice, request.l2GasPerPubdataByteLimit);
        uint256 baseCost = _params.l2GasPrice * request.l2GasLimit;
        if (request.mintValue < baseCost + request.l2Value) {
            revert MsgValueTooLow(baseCost + request.l2Value, request.mintValue);
        }

        request.refundRecipient = AddressAliasHelper.actualRefundRecipient(request.refundRecipient, request.sender);
        // Change the sender address if it is a smart contract to prevent address collision between L1 and L2.
        // Please note, currently ZKsync address derivation is different from Ethereum one, but it may be changed in the future.
        // solhint-disable avoid-tx-origin
        // slither-disable-next-line tx-origin
        if (request.sender != tx.origin) {
            request.sender = AddressAliasHelper.applyL1ToL2Alias(request.sender);
        }

        // populate missing fields
        _params.expirationTimestamp = uint64(block.timestamp + PRIORITY_EXPIRATION); // Safe to cast

        L2CanonicalTransaction memory transaction;
        (transaction, canonicalTxHash) = _validateTx(_params);

        _writePriorityOp(transaction, _params.request.factoryDeps, canonicalTxHash, _params.expirationTimestamp);
        if (s.settlementLayer != address(0)) {
            address assetRouter = IBridgehub(s.bridgehub).assetRouter();
            if (_params.request.sender != AddressAliasHelper.applyL1ToL2Alias(assetRouter)) {
                // slither-disable-next-line unused-return
                IMailbox(s.settlementLayer).requestL2TransactionToGatewayMailboxWithBalanceChange({
                    _chainId: s.chainId,
                    _canonicalTxHash: canonicalTxHash,
                    _expirationTimestamp: _params.expirationTimestamp,
                    _baseTokenAmount: _params.request.mintValue,
                    _getBalanceChange: false
                });
            } else {
                // slither-disable-next-line unused-return
                IMailbox(s.settlementLayer).requestL2TransactionToGatewayMailboxWithBalanceChange({
                    _chainId: s.chainId,
                    _canonicalTxHash: canonicalTxHash,
                    _expirationTimestamp: _params.expirationTimestamp,
                    _baseTokenAmount: _params.request.mintValue,
                    _getBalanceChange: true
                });
            }
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
            l2GasPrice: 0,
            expirationTimestamp: uint64(block.timestamp + PRIORITY_EXPIRATION)
        });

        L2CanonicalTransaction memory transaction;
        (transaction, canonicalTxHash) = _validateTx(params);
        _writePriorityOp(transaction, params.request.factoryDeps, canonicalTxHash, params.expirationTimestamp);
    }

    function _serializeL2Transaction(
        WritePriorityOpParams memory _priorityOpParams
    ) internal pure returns (L2CanonicalTransaction memory transaction) {
        BridgehubL2TransactionRequest memory request = _priorityOpParams.request;
        transaction = L2CanonicalTransaction({
            txType: PRIORITY_OPERATION_L2_TX_TYPE,
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
        TransactionValidator.validateL1ToL2Transaction(
            transaction,
            transactionEncoding,
            s.priorityTxMaxGasLimit,
            s.feeParams.priorityTxMaxPubdata
        );
        canonicalTxHash = keccak256(transactionEncoding);
    }

    /// @notice Stores a transaction record in storage & send event about that
    function _writePriorityOp(
        L2CanonicalTransaction memory _transaction,
        bytes[] memory _factoryDeps,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) internal {
        _writePriorityOpHash(_canonicalTxHash, _expirationTimestamp);

        // Data that is needed for the operator to simulate priority queue offchain
        // solhint-disable-next-line func-named-parameters
        emit NewPriorityRequest(_transaction.nonce, _canonicalTxHash, _expirationTimestamp, _transaction, _factoryDeps);
        emit NewPriorityRequestId(_transaction.nonce, _canonicalTxHash);
    }

    // solhint-disable-next-line no-unused-vars
    function _writePriorityOpHash(bytes32 _canonicalTxHash, uint64 _expirationTimestamp) internal {
        s.priorityTree.push(_canonicalTxHash);
    }

    ///////////////////////////////////////////////////////
    //////// Legacy Era functions

    /// @inheritdoc IMailboxImpl
    function finalizeEthWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external nonReentrant onlyL1 {
        if (s.chainId != ERA_CHAIN_ID) {
            revert OnlyEraSupported();
        }
        address sharedBridge = IBridgehub(s.bridgehub).assetRouter();
        IL1AssetRouter(sharedBridge).finalizeWithdrawal({
            _chainId: ERA_CHAIN_ID,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
    }

    /// @inheritdoc IMailboxImpl
    function requestL2Transaction(
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
        address sharedBridge = IBridgehub(s.bridgehub).assetRouter();
        IL1AssetRouter(sharedBridge).bridgehubDepositBaseToken{value: msg.value}(
            s.chainId,
            s.baseTokenAssetId,
            msg.sender,
            msg.value
        );
    }
}
