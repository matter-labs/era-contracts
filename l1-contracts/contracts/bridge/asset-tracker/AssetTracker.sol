// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {IAssetTracker} from "./IAssetTracker.sol";
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, L2Log, L2Message} from "../../common/Messaging.sol";
import {L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_INTEROP_CENTER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_NATIVE_TOKEN_VAULT, L2_BRIDGEHUB} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {InsufficientChainBalanceAssetTracker, InvalidInteropCalldata, InvalidMessage, InvalidProof, ReconstructionMismatch, Unauthorized, ChainIdNotRegistered} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOGS_MERKLE_TREE_DEPTH} from "../../common/Config.sol";
import {AssetHandlerModifiers} from "../interfaces/AssetHandlerModifiers.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {FinalizeL1DepositParams} from "../../bridge/interfaces/IL1Nullifier.sol";

import {TransientPrimitivesLib} from "../../common/libraries/TransientPrimitves/TransientPrimitives.sol";
import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";
// import {IChainAssetHandler} from "../../bridgehub/IChainAssetHandler.sol";
import {NotMigratedChain, InvalidAssetId, InvalidAmount, InvalidChainId, InvalidSender} from "./AssetTrackerErrors.sol";

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

    /// @dev Specifies the settlement layer for each token to track migrations.
    /// @dev Only used on settlement layers
    mapping(bytes32 assetId => uint256 settlementLayer) public assetSettlementLayer;

    /// @dev Maps the migration number for each asset on the L2.
    mapping(bytes32 assetId => uint256 migrationNumber) public assetMigrationNumber;

    constructor(uint256 _l1ChainId, address _bridgeHub, address, address _nativeTokenVault, address _messageRoot) {
        L1_CHAIN_ID = _l1ChainId;
        BRIDGE_HUB = IBridgehub(_bridgeHub);
        NATIVE_TOKEN_VAULT = INativeTokenVault(_nativeTokenVault);
        MESSAGE_ROOT = IMessageRoot(_messageRoot);
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

    function initialize() external {
        // TODO: implement
    }

    /*//////////////////////////////////////////////////////////////
                    Register token
    //////////////////////////////////////////////////////////////*/

    function registerLegacyToken(bytes32 _assetId) external onlyL1 {
        /// todo migrate balance from ntv here
        assetSettlementLayer[_assetId] = block.chainid;
    }

    function registerNewToken(bytes32 _assetId) external {
        /// todo call from ntv only probably
        /// todo figure out L1 vs L2 differences
        assetSettlementLayer[_assetId] = block.chainid;
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    function handleChainBalanceIncrease(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool) external {
        uint256 settlementLayer = BRIDGE_HUB.settlementLayer(_chainId);
        uint256 chainToUpdate = settlementLayer == block.chainid ? _chainId : settlementLayer;
        if (settlementLayer != block.chainid) {
            TransientPrimitivesLib.set(_chainId, uint256(_assetId));
            TransientPrimitivesLib.set(_chainId + 1, _amount);
        }
        if (!isMinterChain[chainToUpdate][_assetId]) {
            chainBalance[chainToUpdate][_assetId] += _amount;
        }
    }

    function getBalanceChange(uint256 _chainId) external returns (bytes32 assetId, uint256 amount) {
        // kl todo add only chainId.
        assetId = bytes32(TransientPrimitivesLib.getUint256(_chainId));
        amount = TransientPrimitivesLib.getUint256(_chainId + 1);
        TransientPrimitivesLib.set(_chainId, 0);
        TransientPrimitivesLib.set(_chainId + 1, 0);
    }

    function handleChainBalanceDecrease(
        uint256 _tokenOriginChainId,
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool
    ) external {
        uint256 settlementLayer = BRIDGE_HUB.settlementLayer(_chainId);
        uint256 chainToUpdate = settlementLayer == block.chainid ? _chainId : settlementLayer;
        if (_tokenOriginChainId == _chainId && !isMinterChain[chainToUpdate][_assetId]) {
            isMinterChain[chainToUpdate][_assetId] = true;
            return;
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

        uint256 amount = IERC20(tokenAddress).totalSupply();
        uint256 migrationNumber = _getMigrationNumber(block.chainid);

        _sendMigrationDataToL1({
            _chainId: block.chainid,
            _assetId: _assetId,
            _amount: amount,
            _migrationNumber: migrationNumber,
            _isL1ToGateway: true
        });
    }

    /// @notice Migrates the token balance from Gateway to L1.
    /// @dev This function can be called multiple times on the Gateway as it does not have a direct effect.
    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external {
        address zkChain = L2_BRIDGEHUB.getZKChain(_chainId);
        require(zkChain != address(0), ChainIdNotRegistered(_chainId));

        uint256 settlementLayer = L2_BRIDGEHUB.settlementLayer(_chainId);
        require(settlementLayer != block.chainid, NotMigratedChain());

        require(assetSettlementLayer[_assetId] == block.chainid, InvalidAssetId());

        _sendMigrationDataToL1({
            _chainId: _chainId,
            _assetId: _assetId,
            _amount: chainBalance[_chainId][_assetId],
            _migrationNumber: _getMigrationNumber(_chainId),
            _isL1ToGateway: false
        });
    }

    function _getMigrationNumber(uint256 _chainId) internal view returns (uint256) {
        return _chainId - _chainId;
        // return IChainAssetHandler(IBridgehub(BRIDGE_HUB).chainAssetHandler()).migrationNumber(_chainId);
    }

    /// @notice This function receives the migration from the L2 or the Gateway.
    /// @dev It sends the corresponding L1->L2 messages to the L2 and the Gateway.
    function receiveMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        _proveMessageInclusion(_finalizeWithdrawalParams);
        require(_finalizeWithdrawalParams.l2Sender == L2_ASSET_TRACKER_ADDR, InvalidSender());

        // solhint-disable-next-line no-unused-vars
        (
            uint256 chainId,
            bytes32 assetId,
            uint256 amount,
            uint256 migrationNumber,
            bool isL1ToGateway
        ) = _decodeTokenBalanceMigrationData(_finalizeWithdrawalParams.message);

        if (!isL1ToGateway) {
            // here another settlement layer might frontrun
            require(BRIDGE_HUB.whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId), InvalidChainId());
        }

        uint256 currentSettlementLayer = BRIDGE_HUB.settlementLayer(chainId);
        // require(_getMigrationNumber(chainId) == migrationNumber, InvalidMigrationNumber());
        if (isL1ToGateway) {
            require(currentSettlementLayer != block.chainid, NotMigratedChain());
            require(chainId == _finalizeWithdrawalParams.chainId, InvalidChainId());
            require(assetSettlementLayer[assetId] == block.chainid, InvalidAssetId());

            assetSettlementLayer[assetId] = currentSettlementLayer;

            chainBalance[chainId][assetId] -= amount;
            chainBalance[currentSettlementLayer][assetId] += amount;

            _sendConfirmToGateway({
                _settlementLayer: currentSettlementLayer,
                _chainId: chainId,
                _assetId: assetId,
                _amount: amount,
                _isL1ToGateway: isL1ToGateway
            });
            _sendConfirmToL2(chainId, assetId, amount, migrationNumber);
        } else {
            require(currentSettlementLayer == block.chainid, NotMigratedChain());
            require(assetSettlementLayer[assetId] == _finalizeWithdrawalParams.chainId, InvalidAssetId());

            _sendConfirmToGateway({
                _settlementLayer: currentSettlementLayer,
                _chainId: chainId,
                _assetId: assetId,
                _amount: amount,
                _isL1ToGateway: isL1ToGateway
            });

            assetSettlementLayer[assetId] = block.chainid;
            chainBalance[chainId][assetId] += amount;

            _sendConfirmToL2(chainId, assetId, amount, migrationNumber);
        }
    }

    function confirmMigrationOnGateway(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isL1ToGateway
    ) external onlyL1AssetTracker {
        if (_isL1ToGateway) {
            /// In this case the balance might never have been migrated back to L1.
            chainBalance[_chainId][_assetId] += _amount;
        } else {
            require(_amount == chainBalance[_chainId][_assetId], InvalidAmount());
            chainBalance[_chainId][_assetId] = 0;
        }
    }

    function confirmMigrationOnL2(
        uint256,
        bytes32 _assetId,
        uint256,
        uint256 _migrationNumber
    ) external onlyL1AssetTracker {
        assetMigrationNumber[_assetId] = _migrationNumber;
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

    function _sendMigrationDataToL1(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _migrationNumber,
        bool _isL1ToGateway
    ) internal {
        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            _encodeTokenBalanceMigrationData({
                _chainId: _chainId,
                _assetId: _assetId,
                _amount: _amount,
                _migrationNumber: _migrationNumber,
                _isL1ToGateway: _isL1ToGateway
            })
        );
    }

    function _sendConfirmToL2(uint256 _chainId, bytes32 _assetId, uint256 _amount, uint256 _migrationNumber) internal {
        _sendToChain(
            _chainId,
            abi.encodeCall(this.confirmMigrationOnL2, (_chainId, _assetId, _amount, _migrationNumber))
        );
    }

    function _sendConfirmToGateway(
        uint256 _settlementLayer,
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        bool _isL1ToGateway
    ) internal {
        _sendToChain(
            _settlementLayer,
            abi.encodeCall(this.confirmMigrationOnGateway, (_chainId, _assetId, _amount, _isL1ToGateway))
        );
    }

    function _sendToChain(uint256 _chainId, bytes memory _data) internal {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(L2_ASSET_TRACKER_ADDR, _data);
    }

    function _encodeTokenBalanceMigrationData(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _migrationNumber,
        bool _isL1ToGateway
    ) internal pure returns (bytes memory) {
        return abi.encode(_chainId, _assetId, _amount, _migrationNumber, _isL1ToGateway);
    }

    function _decodeTokenBalanceMigrationData(
        bytes calldata _data
    )
        internal
        pure
        returns (uint256 chainId, bytes32 assetId, uint256 amount, uint256 migrationNumber, bool isL1ToGateway)
    {
        (chainId, assetId, amount, migrationNumber, isL1ToGateway) = abi.decode(
            _data,
            (uint256, bytes32, uint256, uint256, bool)
        );
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
