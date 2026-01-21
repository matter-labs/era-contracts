// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BALANCE_CHANGE_VERSION, SavedTotalSupply, TOKEN_BALANCE_MIGRATION_DATA_VERSION, INTEROP_BALANCE_CHANGE_VERSION} from "./IAssetTrackerBase.sol";
import {BUNDLE_IDENTIFIER, BalanceChange, InteropBalanceChange, ConfirmBalanceMigrationData, InteropBundle, InteropCall, L2Log, TokenBalanceMigrationData, TxStatus, AssetBalanceChange} from "../../common/Messaging.sol";
import {L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS, L2_BRIDGEHUB, L2_CHAIN_ASSET_HANDLER, L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_COMPRESSOR_ADDR, L2_INTEROP_CENTER_ADDR, L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR, L2_MESSAGE_ROOT, L2_NATIVE_TOKEN_VAULT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, MAX_BUILT_IN_CONTRACT_ADDR, L2_ASSET_ROUTER, L2_BRIDGEHUB_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {AssetRouterBase} from "../asset-router/AssetRouterBase.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {ChainIdNotRegistered, InvalidInteropCalldata, InvalidMessage, ReconstructionMismatch, Unauthorized} from "../../common/L1ContractErrors.sol";
import {CHAIN_TREE_EMPTY_ENTRY_HASH, IMessageRoot, SHARED_ROOT_TREE_EMPTY_HASH} from "../../core/message-root/IMessageRoot.sol";
import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOGS_MERKLE_TREE_DEPTH} from "../../common/Config.sol";
import {IBridgehubBase, BaseTokenData} from "../../core/bridgehub/IBridgehubBase.sol";
import {FullMerkleMemory} from "../../common/libraries/FullMerkleMemory.sol";

import {InvalidAssetId, InvalidBuiltInContractMessage, InvalidCanonicalTxHash, InvalidFunctionSignature, InvalidInteropChainId, InvalidL2ShardId, InvalidServiceLog, InvalidEmptyMessageRoot, RegisterNewTokenNotAllowed, InvalidInteropBalanceChange} from "./AssetTrackerErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {IGWAssetTracker} from "./IGWAssetTracker.sol";
import {MessageHashing} from "../../common/libraries/MessageHashing.sol";
import {IL1ERC20Bridge} from "../interfaces/IL1ERC20Bridge.sol";
import {IMailboxImpl} from "../../state-transition/chain-interfaces/IMailboxImpl.sol";
import {IAssetTrackerDataEncoding} from "./IAssetTrackerDataEncoding.sol";
import {LegacySharedBridgeAddresses, SharedBridgeOnChainId} from "./LegacySharedBridgeAddresses.sol";
import {InteropDataEncoding} from "../../interop/InteropDataEncoding.sol";
import {IInteropHandler} from "../../interop/IInteropHandler.sol";

contract GWAssetTracker is AssetTrackerBase, IGWAssetTracker {
    using FullMerkleMemory for FullMerkleMemory.FullTree;
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    uint256 public L1_CHAIN_ID;

    /// @notice Used to track how the balance has changed for each chain during a deposit.
    /// We assume that during a single deposit at most two token balances for a chain are amended:
    /// - base token of the chain.
    /// - bridged token (in case it is a deposit of some sort).
    /// @dev Whenever a failed deposit is processed, the chain balance must be decremented accordingly.
    /// From this, it follows that all failed deposit logs that are ever sent to Gateway must have been routed through this contract,
    /// i.e., a chain cannot migrate on top of ZK Gateway until all deposits that were submitted through L1 have been processed
    /// and vice versa.
    mapping(uint256 chainId => mapping(bytes32 canonicalTxHash => BalanceChange balanceChange)) internal balanceChange;

    /// Used only on Gateway.
    mapping(bytes32 assetId => address originToken) internal originToken;

    /// Used only on Gateway.
    mapping(bytes32 assetId => uint256 originChainId) internal tokenOriginChainId;

    /// Used only on Gateway.
    mapping(uint256 chainId => address legacySharedBridgeAddress) internal legacySharedBridgeAddress;

    /// empty messageRoot calculated for specific chain.
    mapping(uint256 chainId => bytes32 emptyMessageRoot) internal emptyMessageRoot;

    /// @notice We save the chainBalance which equals the chains totalSupply before the first GW->L1 migration so that it can be replayed.
    /// @dev Note, that the balance is only saved for even migration numbers, i.e. when the chain did not settle on top of Gateway.
    /// This is needed so that in the future after e.g. a chain migrated with number N (odd number), we would remember how much funds did it
    /// have right before the migration (when N - 1 was the migration number).
    mapping(uint256 chainId => mapping(uint256 migrationNumber => mapping(bytes32 assetId => SavedTotalSupply savedChainBalance)))
        internal savedChainBalance;

    /// @notice We save the interop call balance change
    mapping(uint256 receivingChainId => mapping(bytes32 bundleHash => InteropBalanceChange interopBalanceChange))
        internal interopBalanceChange;

    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyChain(uint256 _chainId) {
        if (msg.sender != L2_BRIDGEHUB.getZKChain(_chainId)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2InteropCenter() {
        if (msg.sender != L2_INTEROP_CENTER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyBridgehub() {
        if (msg.sender != L2_BRIDGEHUB_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    function setAddresses(uint256 _l1ChainId) external onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
    }

    /// @notice Sets legacy shared bridge addresses for chains that used the old bridging system.
    /// @dev This function is called during upgrades to maintain backwards compatibility with pre-V31 chains.
    /// @dev Legacy bridges are needed to process withdrawal messages from chains that haven't upgraded yet.
    function setLegacySharedBridgeAddress() external onlyUpgrader {
        address l1AssetRouter = address(L2_ASSET_ROUTER.L1_ASSET_ROUTER());
        SharedBridgeOnChainId[] memory sharedBridgeOnChainIds = LegacySharedBridgeAddresses
            .getLegacySharedBridgeAddressOnGateway(l1AssetRouter);
        uint256 length = sharedBridgeOnChainIds.length;
        for (uint256 i = 0; i < length; ++i) {
            legacySharedBridgeAddress[sharedBridgeOnChainIds[i].chainId] = sharedBridgeOnChainIds[i]
                .legacySharedBridgeAddress;
        }
    }

    /// @dev for local testing
    function setLegacySharedBridgeAddressForLocalTesting(
        uint256 _chainId,
        address _legacySharedBridgeAddress
    ) external onlyUpgrader {
        legacySharedBridgeAddress[_chainId] = _legacySharedBridgeAddress;
    }

    function _l1ChainId() internal view returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgehub() internal view returns (IBridgehubBase) {
        return L2_BRIDGEHUB;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVaultBase) {
        return L2_NATIVE_TOKEN_VAULT;
    }

    function _messageRoot() internal view returns (IMessageRoot) {
        return L2_MESSAGE_ROOT;
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    function registerNewToken(bytes32, uint256) public override onlyNativeTokenVault {
        revert RegisterNewTokenNotAllowed();
    }

    function registerBaseTokenOnGateway(BaseTokenData calldata _baseTokenData) external onlyBridgehub {
        _registerToken(_baseTokenData.assetId, _baseTokenData.originalToken, _baseTokenData.originChainId);
    }

    /// @notice The function that is expected to be called by the InteropCenter whenever an L1->L2
    /// transaction gets relayed through ZK Gateway for chain `_chainId`.
    /// @dev Note on trust assumptions: `_chainId` and `_balanceChange` are trusted to be correct, since
    /// they are provided directly by the InteropCenter, which in turn, gets those from the L1 implementation of
    /// the GW Mailbox.
    /// @dev `_canonicalTxHash` is not trusted as it is provided at will by a malicious chain.
    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external onlyL2InteropCenter {
        uint256 chainMigrationNumber = _getChainMigrationNumber(_chainId);

        if (_tokenCanSkipMigrationOnSettlementLayer(_chainId, _balanceChange.assetId)) {
            _forceSetAssetMigrationNumber(_chainId, _balanceChange.assetId);
        }
        if (_tokenCanSkipMigrationOnSettlementLayer(_chainId, _balanceChange.baseTokenAssetId)) {
            _forceSetAssetMigrationNumber(_chainId, _balanceChange.baseTokenAssetId);
        }

        /// Note we don't decrease L1ChainBalance here, since we don't track L1 chainBalance on Gateway.
        _increaseAndSaveChainBalance(_chainId, _balanceChange.assetId, _balanceChange.amount, chainMigrationNumber);
        _increaseAndSaveChainBalance(
            _chainId,
            _balanceChange.baseTokenAssetId,
            _balanceChange.baseTokenAmount,
            chainMigrationNumber
        );

        _registerToken(_balanceChange.assetId, _balanceChange.originToken, _balanceChange.tokenOriginChainId);

        /// A malicious chain can cause a collision for the canonical tx hash.
        require(balanceChange[_chainId][_canonicalTxHash].version == 0, InvalidCanonicalTxHash(_canonicalTxHash));
        // we save the balance change to be able to handle failed deposits.

        balanceChange[_chainId][_canonicalTxHash] = _balanceChange;
    }

    /// @notice Sets a legacy shared bridge address for a specific chain.
    /// @param _chainId The chain ID for which to set the legacy bridge address.
    /// @param _legacySharedBridgeAddress The address of the legacy shared bridge contract.
    function setLegacySharedBridgeAddress(
        uint256 _chainId,
        address _legacySharedBridgeAddress
    ) external onlyServiceTransactionSender {
        legacySharedBridgeAddress[_chainId] = _legacySharedBridgeAddress;
    }

    /*//////////////////////////////////////////////////////////////
                    Chain settlement logs processing on Gateway
    //////////////////////////////////////////////////////////////*/

    /// @notice Processes L2->Gateway logs and messages to update chain balances and handle cross-chain operations.
    /// @dev This is the main function that processes a batch of L2 logs from a settling chain.
    /// @dev It reconstructs the logs Merkle tree, validates messages, and routes them to appropriate handlers.
    /// @dev The function handles multiple types of messages: interop, base token, asset router, and system messages.
    /// @param _processLogsInputs The input containing logs, messages, and chain information to process.
    function processLogsAndMessages(
        ProcessLogsInput calldata _processLogsInputs
    ) external onlyChain(_processLogsInputs.chainId) {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory reconstructedLogsTree;
        reconstructedLogsTree.createTree(L2_TO_L1_LOGS_MERKLE_TREE_DEPTH);

        // slither-disable-next-line unused-return
        reconstructedLogsTree.setup(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH);

        uint256 msgCount = 0;
        uint256 logsLength = _processLogsInputs.logs.length;
        bytes32 baseTokenAssetId = _bridgehub().baseTokenAssetId(_processLogsInputs.chainId);
        for (uint256 logCount = 0; logCount < logsLength; ++logCount) {
            L2Log memory log = _processLogsInputs.logs[logCount];
            {
                bytes32 hashedLog = MessageHashing.getLeafHashFromLog(log);
                // slither-disable-next-line unused-return
                reconstructedLogsTree.push(hashedLog);
            }
            if (log.sender == L2_BOOTLOADER_ADDRESS) {
                _handlePotentialFailedDeposit(_processLogsInputs.chainId, log.key, log.value);
            } else if (log.sender == L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR) {
                ++msgCount;
                bytes calldata message = _processLogsInputs.messages[msgCount - 1];

                if (log.value != keccak256(message)) {
                    revert InvalidMessage();
                }
                require(log.l2ShardId == 0, InvalidL2ShardId());
                require(log.isService, InvalidServiceLog());

                if (log.key == bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR)))) {
                    _handleInteropCenterMessage(_processLogsInputs.chainId, message);
                } else if (log.key == bytes32(uint256(uint160(L2_INTEROP_HANDLER_ADDR)))) {
                    _handleInteropHandlerReceiveMessage(_processLogsInputs.chainId, message, baseTokenAssetId);
                } else if (log.key == bytes32(uint256(uint160(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR)))) {
                    _handleBaseTokenSystemContractMessage(_processLogsInputs.chainId, baseTokenAssetId, message);
                } else if (log.key == bytes32(uint256(uint160(L2_ASSET_ROUTER_ADDR)))) {
                    _handleAssetRouterMessage(_processLogsInputs.chainId, message);
                } else if (log.key == bytes32(uint256(uint160(L2_ASSET_TRACKER_ADDR)))) {
                    _checkAssetTrackerMessageSelector(message);
                } else if (log.key == bytes32(uint256(uint160(L2_COMPRESSOR_ADDR)))) {
                    // No further action is required in this case.
                } else if (log.key == bytes32(uint256(uint160(L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR)))) {
                    // No further action is required in this case.
                } else if (uint256(log.key) <= MAX_BUILT_IN_CONTRACT_ADDR) {
                    // This Log is not supported
                    revert InvalidBuiltInContractMessage(logCount, msgCount - 1, log.key);
                } else {
                    address legacySharedBridge = legacySharedBridgeAddress[_processLogsInputs.chainId];
                    if (log.key == bytes32(uint256(uint160(legacySharedBridge))) && legacySharedBridge != address(0)) {
                        _handleLegacySharedBridgeMessage(_processLogsInputs.chainId, message);
                    }
                }
            }
        }
        reconstructedLogsTree.extendUntilEnd();
        bytes32 localLogsRootHash = reconstructedLogsTree.root();

        bytes32 emptyMessageRootForChain = _getEmptyMessageRoot(_processLogsInputs.chainId);
        require(
            _processLogsInputs.messageRoot == emptyMessageRootForChain,
            InvalidEmptyMessageRoot(emptyMessageRootForChain, _processLogsInputs.messageRoot)
        );
        bytes32 chainBatchRootHash = keccak256(bytes.concat(localLogsRootHash, _processLogsInputs.messageRoot));

        if (chainBatchRootHash != _processLogsInputs.chainBatchRoot) {
            revert ReconstructionMismatch(chainBatchRootHash, _processLogsInputs.chainBatchRoot);
        }

        ///  Appends the batch message root to the global message.
        /// The logic of this function depends on the settlement layer as we support
        /// message root aggregation only on non-L1 settlement layers for ease for migration.
        _messageRoot().addChainBatchRoot(
            _processLogsInputs.chainId,
            _processLogsInputs.batchNumber,
            chainBatchRootHash
        );
    }

    function _getEmptyMessageRoot(uint256 _chainId) internal returns (bytes32) {
        bytes32 savedEmptyMessageRoot = emptyMessageRoot[_chainId];
        if (savedEmptyMessageRoot != bytes32(0)) {
            return savedEmptyMessageRoot;
        }
        FullMerkleMemory.FullTree memory sharedTree;
        sharedTree.createTree(1);
        // slither-disable-next-line unused-return
        sharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);

        DynamicIncrementalMerkleMemory.Bytes32PushTree memory chainTree;
        chainTree.createTree(1);
        bytes32 initialChainTreeHash = chainTree.setup(CHAIN_TREE_EMPTY_ENTRY_HASH);
        bytes32 leafHash = MessageHashing.chainIdLeafHash(initialChainTreeHash, _chainId);
        bytes32 emptyMessageRootCalculated = sharedTree.pushNewLeaf(leafHash);

        emptyMessageRoot[_chainId] = emptyMessageRootCalculated;
        return emptyMessageRootCalculated;
    }

    /// @notice Handles potential failed deposits. Not all L1->L2 txs are deposits.
    function _handlePotentialFailedDeposit(uint256 _chainId, bytes32 _canonicalTxHash, bytes32 _value) internal {
        BalanceChange memory savedBalanceChange = balanceChange[_chainId][_canonicalTxHash];
        balanceChange[_chainId][_canonicalTxHash] = BalanceChange({
            version: 0,
            originToken: address(0),
            assetId: bytes32(0),
            amount: 0,
            baseTokenAssetId: bytes32(0),
            baseTokenAmount: 0,
            tokenOriginChainId: 0
        });
        require(savedBalanceChange.version == BALANCE_CHANGE_VERSION, InvalidCanonicalTxHash(_canonicalTxHash));
        if (_value == bytes32(uint256(TxStatus.Success))) {
            return;
        }
        /// Note we handle failedDeposits here for deposits that do not go through GW during chainMigration,
        /// because they were initiated when the chain settles on L1, however the failedDeposit L2->L1 message goes through GW.
        /// Here we do not need to decrement the chainBalance, since the chainBalance was added to the chain's chainBalance on L1,
        /// and never migrated to the GW's chainBalance, since it never increments the totalSupply since the L2 txs fails.
        if (savedBalanceChange.amount > 0) {
            _decreaseChainBalance(_chainId, savedBalanceChange.assetId, savedBalanceChange.amount);
        }
        /// Note the base token is never native to the chain as of V31.
        if (savedBalanceChange.baseTokenAmount > 0) {
            _decreaseChainBalance(_chainId, savedBalanceChange.baseTokenAssetId, savedBalanceChange.baseTokenAmount);
        }
    }

    function _handleInteropCenterMessage(uint256 _chainId, bytes calldata _message) internal {
        if (_message[0] != BUNDLE_IDENTIFIER) {
            // This should not be possible in V31. In V31 this will be a trigger.
            return;
        }

        InteropBundle memory interopBundle = abi.decode(_message[1:], (InteropBundle));

        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(_chainId, _message[1:]);
        interopBalanceChange[interopBundle.destinationChainId][bundleHash].version = INTEROP_BALANCE_CHANGE_VERSION;

        uint256 totalBaseTokenAmount = 0;

        uint256 interopBundleCallsLength = interopBundle.calls.length;

        for (uint256 callCount = 0; callCount < interopBundleCallsLength; ++callCount) {
            InteropCall memory interopCall = interopBundle.calls[callCount];

            if (interopCall.value > 0) {
                totalBaseTokenAmount += interopCall.value;
            }

            // e.g. for direct calls we just skip
            if (interopCall.from != L2_ASSET_ROUTER_ADDR) {
                continue;
            }

            if (bytes4(interopCall.data) != AssetRouterBase.finalizeDeposit.selector) {
                revert InvalidInteropCalldata(bytes4(interopCall.data));
            }
            // solhint-disable-next-line
            _processInteropCall(_chainId, bundleHash, interopCall, interopBundle.destinationChainId);
        }
        bytes32 destinationChainBaseTokenAssetId = _bridgehub().baseTokenAssetId(interopBundle.destinationChainId);
        _decreaseChainBalance(_chainId, destinationChainBaseTokenAssetId, totalBaseTokenAmount);
        interopBalanceChange[interopBundle.destinationChainId][bundleHash].baseTokenAmount = totalBaseTokenAmount;
    }

    function _processInteropCall(
        uint256 _chainId,
        bytes32 _bundleHash,
        InteropCall memory _interopCall,
        uint256 _destinationChainId
    ) internal {
        (uint256 fromChainId, bytes32 assetId, bytes memory transferData) = this.parseInteropCall(_interopCall.data);

        require(_chainId == fromChainId, InvalidInteropChainId(fromChainId, _destinationChainId));

        // solhint-disable-next-line func-named-parameters
        uint256 amount = _handleAssetRouterMessageInner(_chainId, _destinationChainId, assetId, transferData, true);

        AssetBalanceChange memory change = AssetBalanceChange({assetId: assetId, amount: amount});
        interopBalanceChange[_destinationChainId][_bundleHash].assetBalanceChanges.push(change);
    }

    function _handleInteropHandlerReceiveMessage(
        uint256 _chainId,
        bytes calldata _message,
        bytes32 _baseTokenAssetId
    ) internal {
        bytes4 functionSelector = bytes4(_message[0:4]);
        require(functionSelector == IInteropHandler.verifyBundle.selector, InvalidFunctionSignature(functionSelector));
        bytes32 bundleHash = bytes32(_message[4:36]);

        InteropBalanceChange memory receivedInteropBalanceChange = interopBalanceChange[_chainId][bundleHash];
        require(
            receivedInteropBalanceChange.version == INTEROP_BALANCE_CHANGE_VERSION,
            InvalidInteropBalanceChange(bundleHash)
        );
        interopBalanceChange[_chainId][bundleHash].version = 0;

        uint256 length = receivedInteropBalanceChange.assetBalanceChanges.length;
        uint256 chainMigrationNumber = _getChainMigrationNumber(_chainId);
        for (uint256 i = 0; i < length; ++i) {
            uint256 amount = receivedInteropBalanceChange.assetBalanceChanges[i].amount;
            interopBalanceChange[_chainId][bundleHash].assetBalanceChanges[i].assetId = bytes32(0);
            interopBalanceChange[_chainId][bundleHash].assetBalanceChanges[i].amount = 0;
            _increaseAndSaveChainBalance(
                _chainId,
                receivedInteropBalanceChange.assetBalanceChanges[i].assetId,
                amount,
                chainMigrationNumber
            );
        }
        interopBalanceChange[_chainId][bundleHash].baseTokenAmount = 0;
        _increaseAndSaveChainBalance(
            _chainId,
            _baseTokenAssetId,
            receivedInteropBalanceChange.baseTokenAmount,
            chainMigrationNumber
        );
    }

    /// @notice L2->L1 withdrawals go through the L2AssetRouter directly.
    function _handleAssetRouterMessage(uint256 _chainId, bytes memory _message) internal {
        // slither-disable-next-line unused-return
        (bytes4 functionSignature, , bytes32 assetId, bytes memory transferData) = DataEncoding
            .decodeAssetRouterFinalizeDepositData(_message);
        require(
            functionSignature == AssetRouterBase.finalizeDeposit.selector,
            InvalidFunctionSignature(functionSignature)
        );
        // solhint-disable-next-line func-named-parameters
        _handleAssetRouterMessageInner(_chainId, L1_CHAIN_ID, assetId, transferData, false);
    }

    /// @notice Handles the logic of the AssetRouter message.
    /// @param _sourceChainId The chain id of the source chain. Can not be L1.
    /// @param _destinationChainId The chain id of the destination chain. Can be L1.
    /// @param _assetId The asset id of the asset.
    /// @param _transferData The transfer data of the asset.
    /// @dev This function is used to handle the logic of the AssetRouter message.

    function _handleAssetRouterMessageInner(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        bytes32 _assetId,
        bytes memory _transferData,
        bool _isInteropCall
    ) internal returns (uint256 amount) {
        address originalToken;
        bytes memory erc20Metadata;
        // slither-disable-next-line unused-return
        (, , originalToken, amount, erc20Metadata) = DataEncoding.decodeBridgeMintData(_transferData);
        // slither-disable-next-line unused-return
        (uint256 tokenOriginalChainId, , , ) = this.parseTokenData(erc20Metadata);
        DataEncoding.assetIdCheck(tokenOriginalChainId, _assetId, originalToken);
        _registerToken(_assetId, originalToken, tokenOriginalChainId);

        _handleChainBalanceChangeOnGateway({
            _sourceChainId: _sourceChainId,
            _destinationChainId: _destinationChainId,
            _assetId: _assetId,
            _amount: amount,
            _isInteropCall: _isInteropCall
        });
    }

    function _handleChainBalanceChangeOnGateway(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isInteropCall
    ) internal {
        if (_amount > 0) {
            /// Note, we don't track L1 chainBalance on Gateway.
            if (_sourceChainId != L1_CHAIN_ID) {
                _decreaseChainBalance(_sourceChainId, _assetId, _amount);
            }
            if (_destinationChainId != L1_CHAIN_ID && !_isInteropCall) {
                uint256 chainMigrationNumber = _getChainMigrationNumber(_destinationChainId);
                _increaseAndSaveChainBalance(_destinationChainId, _assetId, _amount, chainMigrationNumber);
            }
        }
    }

    /// @notice Handles withdrawal messages from legacy shared bridge contracts on pre-V31 chains.
    /// @dev This function provides backwards compatibility for chains that used the old bridge system.
    /// @param _chainId The chain ID that sent the legacy withdrawal message.
    /// @param _message The raw legacy bridge message containing withdrawal data.
    function _handleLegacySharedBridgeMessage(uint256 _chainId, bytes memory _message) internal {
        (bytes4 functionSignature, address l1Token, bytes memory transferData) = DataEncoding
            .decodeLegacyFinalizeWithdrawalData(L1_CHAIN_ID, _message);
        require(
            functionSignature == IL1ERC20Bridge.finalizeWithdrawal.selector,
            InvalidFunctionSignature(functionSignature)
        );
        /// The legacy shared bridge message is only for L1 tokens on legacy chains where the legacy L2 shared bridge is deployed.
        // Convert legacy L1 token to modern asset ID format
        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);

        // Process the withdrawal using the modern asset router logic
        // slither-disable-next-line unused-return
        _handleAssetRouterMessageInner({
            _sourceChainId: _chainId,
            _destinationChainId: L1_CHAIN_ID,
            _assetId: expectedAssetId,
            _transferData: transferData,
            _isInteropCall: false
        });
    }

    /// @notice L2->L1 base token withdrawals go through the L2BaseTokenSystemContract directly.
    function _handleBaseTokenSystemContractMessage(
        uint256 _chainId,
        bytes32 _baseTokenAssetId,
        bytes memory _message
    ) internal {
        // slither-disable-next-line unused-return
        (bytes4 functionSignature, , uint256 amount) = DataEncoding.decodeBaseTokenFinalizeWithdrawalData(_message);
        require(
            functionSignature == IMailboxImpl.finalizeEthWithdrawal.selector,
            InvalidFunctionSignature(functionSignature)
        );
        _decreaseChainBalance(_chainId, _baseTokenAssetId, amount);
    }

    /// @notice this function is a bit unintuitive since the Gateway AssetTracker checks the messages sent by the L2 AssetTracker,
    /// since we check the messages from all built-in contracts.
    /// However this is not where the receiveMigrationOnL1 function is processed, but on L1.
    function _checkAssetTrackerMessageSelector(bytes memory _message) internal pure {
        bytes4 functionSignature = DataEncoding.getSelector(_message);
        require(
            functionSignature == IAssetTrackerDataEncoding.receiveMigrationOnL1.selector,
            InvalidFunctionSignature(functionSignature)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    Gateway related token balance migration 
    //////////////////////////////////////////////////////////////*/

    /// @notice used to pause deposits on Gateway from L1 for migration back to L1.
    function requestPauseDepositsForChain(uint256 _chainId) external onlyServiceTransactionSender {
        address zkChain = _bridgehub().getZKChain(_chainId);
        require(zkChain != address(0), ChainIdNotRegistered(_chainId));
        IMailboxImpl(zkChain).pauseDepositsOnGateway(block.timestamp);
    }

    /// @notice Migrates the token balance from Gateway to L1.
    /// @dev This function can be called multiple times on the Gateway as it saves the chainBalance on the first call.
    /// @dev This function is permissionless.
    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external {
        address zkChain = L2_BRIDGEHUB.getZKChain(_chainId);
        require(zkChain != address(0), ChainIdNotRegistered(_chainId));

        // If the chain already migrated back to GW, then we need the previous migration number.
        uint256 chainMigrationNumber = _calculatePreviousChainMigrationNumber(_chainId);
        require(assetMigrationNumber[_chainId][_assetId] < chainMigrationNumber, InvalidAssetId(_assetId));
        // We don't save chainBalance here since it might not be the final chainBalance for this value of the chainMigrationNumber.
        uint256 amount = _getOrSaveChainBalance(_chainId, _assetId, chainMigrationNumber);

        TokenBalanceMigrationData memory tokenBalanceMigrationData = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: _chainId,
            assetId: _assetId,
            tokenOriginChainId: tokenOriginChainId[_assetId],
            amount: amount,
            chainMigrationNumber: chainMigrationNumber,
            assetMigrationNumber: assetMigrationNumber[_chainId][_assetId],
            originToken: originToken[_assetId],
            isL1ToGateway: false
        });

        _sendMigrationDataToL1(tokenBalanceMigrationData);
    }

    function _calculatePreviousChainMigrationNumber(uint256 _chainId) internal view returns (uint256) {
        uint256 settlementLayer = L2_BRIDGEHUB.settlementLayer(_chainId);
        uint256 chainMigrationNumber = _getChainMigrationNumber(_chainId);
        // If the chain already migrated back to GW, then we need the previous migration number.
        if (settlementLayer == block.chainid) {
            --chainMigrationNumber;
        }
        return chainMigrationNumber;
    }

    /// @notice Gets the chain balance for migration, saving it if this is the first time it's accessed.
    /// @dev This function implements a "snapshot and clear" pattern for chain balances during migration.
    /// @dev On first access, it saves the current chainBalance and sets it to 0 to prevent double-spending.
    /// @dev Subsequent accesses return the saved value without modifying the current chainBalance.
    /// @param _chainId The chain ID whose balance is being queried.
    /// @param _assetId The asset ID of the token.
    /// @param _migrationNumber The migration number for this operation.
    /// @return The saved chain balance for this migration.
    function _getOrSaveChainBalance(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _migrationNumber
    ) internal returns (uint256) {
        // Check if we've already saved the balance for this migration
        SavedTotalSupply memory tokenSavedTotalSupply = savedChainBalance[_chainId][_migrationNumber][_assetId];
        if (!tokenSavedTotalSupply.isSaved) {
            // First time accessing this balance for this migration number
            // Save the current balance and reset the chainBalance to 0
            tokenSavedTotalSupply.amount = chainBalance[_chainId][_assetId];
            // Persist the saved balance for this specific migration
            savedChainBalance[_chainId][_migrationNumber][_assetId] = SavedTotalSupply({
                isSaved: true,
                amount: tokenSavedTotalSupply.amount
            });
        }

        // Return the balance that was available at the time of this migration
        return tokenSavedTotalSupply.amount;
    }

    /// @notice Confirms a migration operation has been completed and updates the asset migration number.
    /// @param _data The migration confirmation data containing chain ID, asset ID, and migration number.
    function confirmMigrationOnGateway(
        ConfirmBalanceMigrationData calldata _data
    ) external onlyServiceTransactionSender {
        assetMigrationNumber[_data.chainId][_data.assetId] = _data.migrationNumber;
        // Register the token if it wasn't already
        if (originToken[_data.assetId] == address(0)) {
            originToken[_data.assetId] = _data.originToken;
            tokenOriginChainId[_data.assetId] = _data.tokenOriginChainId;
        }
        if (_data.isL1ToGateway) {
            /// In this case the balance might never have been migrated back to L1.
            chainBalance[_data.chainId][_data.assetId] += _data.amount;
        } else {
            _decreaseChainBalance(_data.chainId, _data.assetId, _data.amount);

            uint256 chainMigrationNumber = _calculatePreviousChainMigrationNumber(_data.chainId);
            SavedTotalSupply memory savedBalance = savedChainBalance[_data.chainId][chainMigrationNumber][
                _data.assetId
            ];
            if (savedBalance.isSaved) {
                savedChainBalance[_data.chainId][chainMigrationNumber][_data.assetId].amount =
                    savedBalance.amount -
                    _data.amount;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Helper Functions
    //////////////////////////////////////////////////////////////*/

    function _increaseAndSaveChainBalance(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _chainMigrationNumber
    ) internal {
        // We save the chainBalance for the previous migration number so that the chain balance can be migrated back to GW in case it was not migrated.
        // Note, that for this logic to be correct, we need to ensure that `_chainMigrationNumber` is odd, i.e. the chain actually
        // actively settles on top of Gateway.
        _getOrSaveChainBalance(_chainId, _assetId, _chainMigrationNumber - 1);
        // we increase the chain balance of the token.
        if (_amount > 0) {
            chainBalance[_chainId][_assetId] += _amount;
        }
    }

    function _registerToken(bytes32 _assetId, address _originalToken, uint256 _tokenOriginChainId) internal {
        if (originToken[_assetId] == address(0)) {
            originToken[_assetId] = _originalToken;
            tokenOriginChainId[_assetId] = _tokenOriginChainId;
        }
    }

    /// @notice Parses interop call data to extract transfer information.
    /// @param _callData The encoded call data containing transfer information.
    /// @return fromChainId The chain ID from which the transfer originates.
    /// @return assetId The asset ID of the token being transferred.
    /// @return transferData The encoded transfer data.
    function parseInteropCall(
        bytes calldata _callData
    ) external pure returns (uint256 fromChainId, bytes32 assetId, bytes memory transferData) {
        (fromChainId, assetId, transferData) = abi.decode(_callData[4:], (uint256, bytes32, bytes));
    }

    /// @notice Parses token metadata from encoded token data.
    /// @param _tokenData The encoded token metadata.
    /// @return originChainId The chain ID where the token was originally created.
    /// @return name The token name as encoded bytes.
    /// @return symbol The token symbol as encoded bytes.
    /// @return decimals The token decimals as encoded bytes.
    function parseTokenData(
        bytes calldata _tokenData
    ) external pure returns (uint256 originChainId, bytes memory name, bytes memory symbol, bytes memory decimals) {
        (originChainId, name, symbol, decimals) = DataEncoding.decodeTokenData(_tokenData);
    }

    function _getChainMigrationNumber(uint256 _chainId) internal view override returns (uint256) {
        return L2_CHAIN_ASSET_HANDLER.migrationNumber(_chainId);
    }
}
