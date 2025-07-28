// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {IAssetTracker, TokenBalanceMigrationData} from "./IAssetTracker.sol";
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, L2Log, L2Message, TxStatus} from "../../common/Messaging.sol";
import {L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_BRIDGEHUB, L2_CHAIN_ASSET_HANDLER, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {InvalidInteropCalldata, InvalidMessage, InvalidProof, ReconstructionMismatch, Unauthorized, ChainIdNotRegistered} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOGS_MERKLE_TREE_DEPTH, SERVICE_TRANSACTION_SENDER} from "../../common/Config.sol";
import {AssetHandlerModifiers} from "../interfaces/AssetHandlerModifiers.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {FinalizeL1DepositParams, IL1Nullifier} from "../../bridge/interfaces/IL1Nullifier.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {IL1NativeTokenVault} from "../../bridge/ntv/IL1NativeTokenVault.sol";

import {TransientPrimitivesLib} from "../../common/libraries/TransientPrimitives/TransientPrimitives.sol";
import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";
import {IChainAssetHandler} from "../../bridgehub/IChainAssetHandler.sol";
import {InsufficientChainBalanceAssetTracker, InvalidAmount, InvalidMigrationNumber, InvalidAssetId, InvalidAssetMigrationNumber, InvalidSender, InvalidWithdrawalChainId, NotMigratedChain} from "./AssetTrackerErrors.sol";

contract AssetTracker is IAssetTracker, Ownable2StepUpgradeable, AssetHandlerModifiers {
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    uint256 public immutable L1_CHAIN_ID;

    IBridgehub public immutable BRIDGE_HUB;

    INativeTokenVault public immutable NATIVE_TOKEN_VAULT;

    IMessageRoot public immutable MESSAGE_ROOT;

    address public immutable L1_ASSET_TRACKER;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// NOTE: this function may be removed in the future, don't rely on it!
    /// @dev For minter chains, the balance is 0.
    /// @dev Only used on settlement layers
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;

    mapping(uint256 chainId => mapping(bytes32 assetId => bool isMinter)) public isMinterChain;

    /// @notice Used on the L2 instead of the settlement layer
    /// @dev Maps the migration number for each asset on the L2.
    /// Needs to be equal to the migration number of the chain for the token to be bridgeable.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 migrationNumber)) internal assetMigrationNumber;

    mapping(uint256 migrationNumber => mapping(bytes32 assetId => uint256 totalSupply)) internal totalSupply;

    mapping(uint256 chainId => mapping(bytes32 canonicalTxHash => BalanceChange balanceChange)) internal balanceChange;

    constructor(uint256 _l1ChainId, address _bridgeHub, address, address _nativeTokenVault, address _messageRoot) {
        L1_CHAIN_ID = _l1ChainId;
        BRIDGE_HUB = IBridgehub(_bridgeHub);
        NATIVE_TOKEN_VAULT = INativeTokenVault(_nativeTokenVault);
        MESSAGE_ROOT = IMessageRoot(_messageRoot);
        // kl todo add L1_ASSET_TRACKER
    }

    /// @notice Checks that the message sender is the L1 asset tracker.
    modifier onlyL1AssetTracker() {
        require(msg.sender == AddressAliasHelper.applyL1ToL2Alias(L1_ASSET_TRACKER), Unauthorized(msg.sender));
        _;
    }

    modifier onlyL1() {
        require(block.chainid == L1_CHAIN_ID, Unauthorized(msg.sender));
        _;
    }

    modifier onlyChainAdmin() {
        // require(msg.sender == , Unauthorized(msg.sender));
        _;
    }

    modifier onlyServiceTransactionSender() {
        require(msg.sender == SERVICE_TRANSACTION_SENDER, Unauthorized(msg.sender));
        _;
    }

    modifier onlyNativeTokenVaultOrInteropCenter() {
        require(
            msg.sender == address(NATIVE_TOKEN_VAULT) || msg.sender == L2_INTEROP_CENTER_ADDR,
            Unauthorized(msg.sender)
        );
        _;
    }

    modifier onlyNativeTokenVault() {
        require(msg.sender == address(NATIVE_TOKEN_VAULT), Unauthorized(msg.sender));
        _;
    }

    function initialize() external {
        // TODO: implement
    }

    function tokenMigratedThisChain(bytes32 _assetId) external view returns (bool) {
        return tokenMigrated(block.chainid, _assetId);
    }

    function tokenMigrated(uint256 _chainId, bytes32 _assetId) public view returns (bool) {
        return assetMigrationNumber[_chainId][_assetId] == _getMigrationNumber(_chainId);
    }

    /*//////////////////////////////////////////////////////////////
                    Register token
    //////////////////////////////////////////////////////////////*/

    function registerLegacyTokenOnChain(bytes32 _assetId) external {
        _registerTokenOnL2(_assetId);
    }

    function registerNewToken(bytes32 _assetId, uint256 _originChainId) external {
        isMinterChain[_originChainId][_assetId] = true;
        /// todo call from ntv only probably
        /// todo figure out L1 vs L2 differences
        if (block.chainid == L1_CHAIN_ID) {
            // _registerTokenOnL1(_assetId);
        } else {
            _registerTokenOnL2(_assetId);
        }
    }

    // function _registerTokenOnL1(bytes32 _assetId) internal {
    // }

    // function _registerTokenOnGateway(bytes32 _assetId) internal {
    // }

    function _registerTokenOnL2(bytes32 _assetId) internal {
        assetMigrationNumber[block.chainid][_assetId] = L2_CHAIN_ASSET_HANDLER.getMigrationNumber(block.chainid);
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    /// @notice Called on the L1 when a deposit to the chain happens.
    /// @notice Also called from the InteropCenter on Gateway during deposits.
    /// @dev As the chain does not update its balance when settling on L1.
    function handleChainBalanceIncreaseOnL1(uint256 _chainId, bytes32 _assetId, uint256 _amount) external {
        // onlyNativeTokenVaultOrInteropCenter {

        uint256 currentSettlementLayer = BRIDGE_HUB.settlementLayer(_chainId);
        uint256 chainToUpdate = currentSettlementLayer == block.chainid ? _chainId : currentSettlementLayer;
        if (currentSettlementLayer != block.chainid) {
            TransientPrimitivesLib.set(_chainId, uint256(_assetId));
            TransientPrimitivesLib.set(_chainId + 1, _amount);
        }
        if (!isMinterChain[chainToUpdate][_assetId]) {
            chainBalance[chainToUpdate][_assetId] += _amount;
        }
    }

    /// @notice Called on the L1 by the chain's mailbox when a deposit happens
    /// @notice Used for deposits via Gateway.
    function getBalanceChange(uint256 _chainId) external returns (bytes32 assetId, uint256 amount) {
        // kl todo add only chainId.
        assetId = bytes32(TransientPrimitivesLib.getUint256(_chainId));
        amount = TransientPrimitivesLib.getUint256(_chainId + 1);
        TransientPrimitivesLib.set(_chainId, 0);
        TransientPrimitivesLib.set(_chainId + 1, 0);
    }

    /// @notice Called on the L1 when a withdrawal from the chain happens, or when a failed deposit is undone.
    /// @dev As the chain does not update its balance when settling on L1.
    function handleChainBalanceDecreaseOnL1(uint256 _chainId, bytes32 _assetId, uint256 _amount) external {
        // onlyNativeTokenVault
        uint256 chainToUpdate = _getWithdrawalChain(_chainId);

        if (chainToUpdate != _chainId) {
            uint256 _tokenOriginChainId = NATIVE_TOKEN_VAULT.originChainId(_assetId);
            if (_chainId == _tokenOriginChainId && chainToUpdate != _chainId) {
                _ensureSettlementLayerIsMinter(_assetId, _tokenOriginChainId);
            }
        }

        if (isMinterChain[chainToUpdate][_assetId]) {
            return;
        }
        // Check that the chain has sufficient balance
        if (chainBalance[chainToUpdate][_assetId] < _amount) {
            revert InsufficientChainBalanceAssetTracker(chainToUpdate, _assetId, _amount);
        }
        chainBalance[chainToUpdate][_assetId] -= _amount;
    }

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        bytes32 _baseTokenAssetId,
        uint256 _baseTokenAmount,
        bytes32 _assetId,
        uint256 _amount
    ) external {
        if (_amount > 0) {
            chainBalance[_chainId][_assetId] += _amount;
        }
        if (_baseTokenAmount > 0) {
            chainBalance[_chainId][_baseTokenAssetId] += _baseTokenAmount;
        }
        balanceChange[_chainId][_canonicalTxHash] = BalanceChange({
            baseTokenAssetId: _baseTokenAssetId,
            baseTokenAmount: _baseTokenAmount,
            assetId: _assetId,
            amount: _amount
        });
    }

    function handleInitiateBridgingOnL2(bytes32 _assetId) external view {
        uint256 migrationNumber = _getMigrationNumber(block.chainid);
        uint256 savedAssetMigrationNumber = assetMigrationNumber[block.chainid][_assetId];
        require(
            savedAssetMigrationNumber == migrationNumber ||
                L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.getSettlementLayerChainId() == L1_CHAIN_ID,
            InvalidAssetMigrationNumber(savedAssetMigrationNumber, migrationNumber)
        );
    }

    function handleFinalizeBridgingOnL2(bytes32 _assetId) external {
        uint256 migrationNumber = _getMigrationNumber(block.chainid);
        if (totalSupply[migrationNumber][_assetId] == 0) {
            totalSupply[migrationNumber][_assetId] = IERC20(L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId)).totalSupply();
        }
    }

    function _getWithdrawalChain(uint256 _chainId) internal view returns (uint256 chainToUpdate) {
        uint256 settlementLayer = IL1Nullifier(IL1NativeTokenVault(address(NATIVE_TOKEN_VAULT)).L1_NULLIFIER())
            .getTransientSettlementLayer();
        chainToUpdate = settlementLayer == 0 ? _chainId : settlementLayer;
    }

    /// we need this function to make sure the settlement layer is up to date.
    function _ensureTokenIsRegistered(bytes32 _assetId, uint256 _tokenOriginChainId) internal {
        if (!isMinterChain[_tokenOriginChainId][_assetId]) {
            isMinterChain[_tokenOriginChainId][_assetId] = true;
        }
        if (_tokenOriginChainId != L1_CHAIN_ID) {
            _ensureSettlementLayerIsMinter(_assetId, _tokenOriginChainId);
        }
    }

    function _ensureSettlementLayerIsMinter(bytes32 _assetId, uint256 _tokenOriginChainId) internal {
        uint256 settlementLayer = BRIDGE_HUB.settlementLayer(_tokenOriginChainId);
        if (settlementLayer != block.chainid && settlementLayer != 0) {
            isMinterChain[settlementLayer][_assetId] = true;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    Chain settlement logs processing
    //////////////////////////////////////////////////////////////*/

    /// note we don't process L1 txs here, since we can do that when accepting the tx.
    // kl todo: estimate the txs size, and how much we can handle on GW.
    function processLogsAndMessages(ProcessLogsInput calldata _processLogsInputs) external {
        uint256 msgCount = 0;
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory reconstructedLogsTree = DynamicIncrementalMerkleMemory
            .Bytes32PushTree({
                _nextLeafIndex: 0,
                _sides: new bytes32[](L2_TO_L1_LOGS_MERKLE_TREE_DEPTH),
                _zeros: new bytes32[](L2_TO_L1_LOGS_MERKLE_TREE_DEPTH),
                _sidesLengthMemory: 0,
                _zerosLengthMemory: 0
            }); // todo 100 to const
        // slither-disable-next-line unused-return
        reconstructedLogsTree.setup(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH);
        uint256 logsLength = _processLogsInputs.logs.length;
        for (uint256 logCount = 0; logCount < logsLength; ++logCount) {
            L2Log memory log = _processLogsInputs.logs[logCount];
            bytes32 hashedLog = keccak256(
                // solhint-disable-next-line func-named-parameters
                abi.encodePacked(log.l2ShardId, log.isService, log.txNumberInBatch, log.sender, log.key, log.value)
            );
            // slither-disable-next-line unused-return
            reconstructedLogsTree.push(hashedLog);
            if (log.sender == L2_BOOTLOADER_ADDRESS && log.value == bytes32(uint256(TxStatus.Failure))) {
                _handlePotentialFailedDeposit(_processLogsInputs.chainId, log.key);
            }
            if (log.sender != L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR) {
                // its just a log and not a message
                continue;
            }
            if (log.key != bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR)))) {
                ++msgCount;
                continue;
            }
            bytes memory message = _processLogsInputs.messages[msgCount];
            ++msgCount;

            if (log.value != keccak256(message)) {
                revert InvalidMessage();
            }
            if (message[0] != BUNDLE_IDENTIFIER) {
                // This should not be possible in V30. In V31 this will be a trigger.
                continue;
            }

            InteropBundle memory interopBundle = this.parseInteropBundle(message);

            // handle msg.value call separately
            InteropCall memory interopCall = interopBundle.calls[0];
            uint256 callsLength = interopBundle.calls.length;
            for (uint256 callCount = 1; callCount < callsLength; ++callCount) {
                interopCall = interopBundle.calls[callCount];

                // e.g. for direct calls we just skip
                if (interopCall.from != L2_ASSET_ROUTER_ADDR) {
                    continue;
                }

                if (bytes4(interopCall.data) != IAssetRouterBase.finalizeDeposit.selector) {
                    revert InvalidInteropCalldata(bytes4(interopCall.data));
                }
                (uint256 fromChainId, bytes32 assetId, bytes memory transferData) = this.parseInteropCall(
                    interopCall.data
                );
                // slither-disable-next-line unused-return
                (, , , uint256 amount, bytes memory erc20Metadata) = DataEncoding.decodeBridgeMintData(transferData);
                // slither-disable-next-line unused-return
                (uint256 tokenOriginChainId, , , ) = this.parseTokenData(erc20Metadata);
                isMinterChain[tokenOriginChainId][assetId] = true;

                // if (!isMinterChain[fromChainId][assetId]) {
                if (tokenOriginChainId != fromChainId) {
                    chainBalance[fromChainId][assetId] -= amount;
                }
                // if (!isMinterChain[interopBundle.destinationChainId][assetId]) {
                if (tokenOriginChainId != interopBundle.destinationChainId) {
                    chainBalance[interopBundle.destinationChainId][assetId] += amount;
                }
            }

            // kl todo add change minter role here
        }
        reconstructedLogsTree.extendUntilEnd();
        bytes32 localLogsRootHash = reconstructedLogsTree.root();
        bytes32 chainBatchRootHash = keccak256(bytes.concat(localLogsRootHash, _processLogsInputs.messageRoot));

        if (chainBatchRootHash != _processLogsInputs.chainBatchRoot) {
            revert ReconstructionMismatch(chainBatchRootHash, _processLogsInputs.chainBatchRoot);
        }

        _appendChainBatchRoot(_processLogsInputs.chainId, _processLogsInputs.batchNumber, chainBatchRootHash);
    }

    /// @notice Handles potential failed deposits. Not all L1->L2 txs are deposits.
    function _handlePotentialFailedDeposit(uint256 _chainId, bytes32 _canonicalTxHash) internal {
        BalanceChange memory savedBalanceChange = balanceChange[_chainId][_canonicalTxHash];
        if (savedBalanceChange.amount > 0) {
            chainBalance[_chainId][savedBalanceChange.assetId] -= savedBalanceChange.amount;
        }
        if (savedBalanceChange.baseTokenAmount > 0) {
            chainBalance[_chainId][savedBalanceChange.baseTokenAssetId] -= savedBalanceChange.baseTokenAmount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    Gateway related token balance migration 
    //////////////////////////////////////////////////////////////*/

    /// @notice Migrates the token balance from L2 to L1.
    /// @dev This function can be called multiple times on the chain it does not have a direct effect.
    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external {
        address tokenAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId);

        if (tokenAddress == address(0)) {
            return;
        }

        uint256 migrationNumber = _getMigrationNumber(block.chainid);
        uint256 amount;
        uint256 savedTotalSupply = totalSupply[migrationNumber][_assetId];
        if (savedTotalSupply == 0) {
            amount = IERC20(tokenAddress).totalSupply();
        } else {
            amount = savedTotalSupply;
        }

        TokenBalanceMigrationData memory tokenBalanceMigrationData = TokenBalanceMigrationData({
            chainId: block.chainid,
            assetId: _assetId,
            tokenOriginChainId: L2_NATIVE_TOKEN_VAULT.originChainId(_assetId),
            amount: amount,
            migrationNumber: migrationNumber,
            isL1ToGateway: true
        });
        _sendMigrationDataToL1(tokenBalanceMigrationData);
    }

    /// @notice Migrates the token balance from Gateway to L1.
    /// @dev This function can be called multiple times on the Gateway as it does not have a direct effect.
    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external {
        address zkChain = L2_BRIDGEHUB.getZKChain(_chainId);
        require(zkChain != address(0), ChainIdNotRegistered(_chainId));

        uint256 settlementLayer = L2_BRIDGEHUB.settlementLayer(_chainId);
        require(settlementLayer != block.chainid, NotMigratedChain());

        uint256 migrationNumber = _getMigrationNumber(_chainId);
        require(assetMigrationNumber[_chainId][_assetId] < migrationNumber, InvalidAssetId());

        TokenBalanceMigrationData memory tokenBalanceMigrationData = TokenBalanceMigrationData({
            chainId: _chainId,
            assetId: _assetId,
            tokenOriginChainId: 0,
            amount: chainBalance[_chainId][_assetId],
            migrationNumber: migrationNumber,
            isL1ToGateway: false
        });

        /// do we want to set this?
        // assetMigrationNumber[_chainId][_assetId] = migrationNumber;
        _sendMigrationDataToL1(tokenBalanceMigrationData);
    }

    function _getMigrationNumber(uint256 _chainId) internal view returns (uint256) {
        // return 1 + _chainId - _chainId;
        return IChainAssetHandler(IBridgehub(BRIDGE_HUB).chainAssetHandler()).getMigrationNumber(_chainId);
    }

    /// @notice This function receives the migration from the L2 or the Gateway.
    /// @dev It sends the corresponding L1->L2 messages to the L2 and the Gateway.
    function receiveMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        _proveMessageInclusion(_finalizeWithdrawalParams);
        require(_finalizeWithdrawalParams.l2Sender == L2_ASSET_TRACKER_ADDR, InvalidSender());

        // solhint-disable-next-line no-unused-vars

        TokenBalanceMigrationData memory data = abi.decode(
            _finalizeWithdrawalParams.message,
            (TokenBalanceMigrationData)
        );
        require(assetMigrationNumber[data.chainId][data.assetId] < data.migrationNumber, InvalidAssetId());

        uint256 currentSettlementLayer = BRIDGE_HUB.settlementLayer(data.chainId);
        // require(_getMigrationNumber(chainId) == migrationNumber, InvalidMigrationNumber());
        if (data.isL1ToGateway) {
            require(currentSettlementLayer != block.chainid, NotMigratedChain());
            require(data.chainId == _finalizeWithdrawalParams.chainId, InvalidWithdrawalChainId());
            uint256 chainMigrationNumber = _getMigrationNumber(data.chainId);

            // we check parity here to make sure that we migrated back to L1 from Gateway.
            // In the future we might initalize chains on GW. So we subtract from chainMigrationNumber.
            require(
                chainMigrationNumber - ((assetMigrationNumber[data.chainId][data.assetId]) % 2) == 1,
                InvalidMigrationNumber()
            );

            _ensureTokenIsRegistered(data.assetId, data.tokenOriginChainId);
            // if (data.tokenOriginChainId != data.chainId) {
            _migrateFunds(data.chainId, currentSettlementLayer, data.assetId, data.amount);
            // }
        } else {
            require(currentSettlementLayer == block.chainid, NotMigratedChain());
            require(
                BRIDGE_HUB.whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId),
                InvalidWithdrawalChainId()
            );

            _ensureTokenIsRegistered(data.assetId, data.tokenOriginChainId);
            _migrateFunds(_finalizeWithdrawalParams.chainId, data.chainId, data.assetId, data.amount);
        }
        assetMigrationNumber[data.chainId][data.assetId] = data.migrationNumber;
        _sendToChain(
            data.isL1ToGateway ? currentSettlementLayer : _finalizeWithdrawalParams.chainId,
            abi.encodeCall(this.confirmMigrationOnGateway, (data))
        );
        _sendToChain(data.chainId, abi.encodeCall(this.confirmMigrationOnL2, (data)));
    }

    function _migrateFunds(uint256 _fromChainId, uint256 _toChainId, bytes32 _assetId, uint256 _amount) internal {
        if (!isMinterChain[_fromChainId][_assetId]) {
            // && data.tokenOriginChainId != _fromChainId) { kl todo can probably remove
            chainBalance[_fromChainId][_assetId] -= _amount;
            chainBalance[_toChainId][_assetId] += _amount;
        }
    }

    function confirmMigrationOnGateway(TokenBalanceMigrationData calldata data) external {
        //onlyServiceTransactionSender {
        assetMigrationNumber[data.chainId][data.assetId] = data.migrationNumber;
        if (data.isL1ToGateway) {
            /// In this case the balance might never have been migrated back to L1.
            chainBalance[data.chainId][data.assetId] += data.amount;
        } else {
            require(data.amount == chainBalance[data.chainId][data.assetId], InvalidAmount());
            chainBalance[data.chainId][data.assetId] = 0;
        }
    }

    function confirmMigrationOnL2(TokenBalanceMigrationData calldata data) external {
        //onlyServiceTransactionSender {
        assetMigrationNumber[block.chainid][data.assetId] = data.migrationNumber;
    }

    function _sendMigrationDataToL1(TokenBalanceMigrationData memory data) internal {
        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(abi.encode(data));
    }

    function _sendToChain(uint256 _chainId, bytes memory _data) internal {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(L2_ASSET_TRACKER_ADDR, _data);
    }

    function _proveMessageInclusion(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) internal view {
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: _finalizeWithdrawalParams.l2TxNumberInBatch,
            sender: L2_ASSET_TRACKER_ADDR,
            data: _finalizeWithdrawalParams.message
        });

        bool success = BRIDGE_HUB.proveL2MessageInclusion({
            _chainId: _finalizeWithdrawalParams.chainId,
            _batchNumber: _finalizeWithdrawalParams.l2BatchNumber,
            _index: _finalizeWithdrawalParams.l2MessageIndex,
            _message: l2ToL1Message,
            _proof: _finalizeWithdrawalParams.merkleProof
        });

        // withdrawal wrong proof
        if (!success) {
            revert InvalidProof();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Helper Functions
    //////////////////////////////////////////////////////////////*/

    function parseInteropBundle(bytes calldata _bundleData) external pure returns (InteropBundle memory interopBundle) {
        interopBundle = abi.decode(_bundleData[1:], (InteropBundle));
    }

    function parseInteropCall(
        bytes calldata _callData
    ) external pure returns (uint256 fromChainId, bytes32 assetId, bytes memory transferData) {
        (fromChainId, assetId, transferData) = abi.decode(_callData[4:], (uint256, bytes32, bytes));
    }

    function parseTokenData(
        bytes calldata _tokenData
    ) external pure returns (uint256 originChainId, bytes memory name, bytes memory symbol, bytes memory decimals) {
        (originChainId, name, symbol, decimals) = DataEncoding.decodeTokenData(_tokenData);
    }

    /// @notice Appends the batch message root to the global message.
    /// @param _batchNumber The number of the batch
    /// @param _messageRoot The root of the merkle tree of the messages to L1.
    /// @dev The logic of this function depends on the settlement layer as we support
    /// message root aggregation only on non-L1 settlement layers for ease for migration.
    function _appendChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _messageRoot) internal {
        MESSAGE_ROOT.addChainBatchRoot(_chainId, _batchNumber, _messageRoot);
    }
}
