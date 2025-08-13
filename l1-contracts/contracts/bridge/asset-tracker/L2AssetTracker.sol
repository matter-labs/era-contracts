// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {BalanceChange, TokenBalanceMigrationData} from "./IAssetTrackerBase.sol";
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, L2Log, TxStatus} from "../../common/Messaging.sol";
import {L2_ASSET_ROUTER, L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BOOTLOADER_ADDRESS, L2_BRIDGEHUB, L2_CHAIN_ASSET_HANDLER, L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {ChainIdNotRegistered, InvalidInteropCalldata, InvalidMessage, ReconstructionMismatch, Unauthorized} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOGS_MERKLE_TREE_DEPTH} from "../../common/Config.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";

import {InvalidAmount, InvalidAssetId, TokenBalanceNotMigratedToGateway, InvalidCanonicalTxHash, NotMigratedChain} from "./AssetTrackerErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {IBridgedStandardToken} from "../BridgedStandardERC20.sol";

struct SavedTotalSupply {
    bool isSaved;
    uint256 amount;
}

contract L2AssetTracker is AssetTrackerBase, IL2AssetTracker {
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    uint256 public L1_CHAIN_ID;

    IBridgehub public BRIDGE_HUB;

    INativeTokenVault public NATIVE_TOKEN_VAULT;

    IMessageRoot public MESSAGE_ROOT;

    mapping(uint256 migrationNumber => mapping(bytes32 assetId => SavedTotalSupply savedTotalSupply))
        internal savedTotalSupply;

    /// used only on L2 to track if the L1->L2 deposits have been processed or not.
    mapping(uint256 migrationNumber => bool isL1ToL2DepositProcessed) internal isL1ToL2DepositProcessed;

    mapping(uint256 chainId => mapping(bytes32 canonicalTxHash => BalanceChange balanceChange)) internal balanceChange;

    /// used only on Gateway.
    mapping(bytes32 assetId => address originToken) internal originToken;

    /// used only on Gateway.
    mapping(bytes32 assetId => uint256 originChainId) internal tokenOriginChainId;

    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2NativeTokenVault() {
        if (msg.sender != L2_NATIVE_TOKEN_VAULT_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyBaseTokenSystemContract() {
        if (msg.sender != address(L2_BASE_TOKEN_SYSTEM_CONTRACT)) {
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

    function setAddresses(
        uint256 _l1ChainId,
        address _bridgehub,
        address,
        address _nativeTokenVault,
        address _messageRoot
    ) external onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
        BRIDGE_HUB = IBridgehub(_bridgehub);
        NATIVE_TOKEN_VAULT = INativeTokenVault(_nativeTokenVault);
        MESSAGE_ROOT = IMessageRoot(_messageRoot);
    }
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgehub() internal view override returns (IBridgehub) {
        return BRIDGE_HUB;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVault) {
        return NATIVE_TOKEN_VAULT;
    }

    function _messageRoot() internal view override returns (IMessageRoot) {
        return MESSAGE_ROOT;
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external {
        if (_balanceChange.amount > 0) {
            chainBalance[_chainId][_balanceChange.assetId] += _balanceChange.amount;
        }
        if (_balanceChange.baseTokenAmount > 0 && _balanceChange.tokenOriginChainId != _chainId) {
            chainBalance[_chainId][_balanceChange.baseTokenAssetId] += _balanceChange.baseTokenAmount;
        }
        _registerToken(_balanceChange.assetId, _balanceChange.originToken, _balanceChange.tokenOriginChainId);

        /// A malicious chain can cause a collision for the canonical tx hash.
        require(balanceChange[_chainId][_canonicalTxHash].amount == 0, InvalidCanonicalTxHash(_canonicalTxHash));
        balanceChange[_chainId][_canonicalTxHash] = _balanceChange;
    }

    function handleInitiateBridgingOnL2(bytes32 _assetId) public view {
        uint256 migrationNumber = _getMigrationNumber(block.chainid);
        uint256 savedAssetMigrationNumber = assetMigrationNumber[block.chainid][_assetId];
        require(
            savedAssetMigrationNumber == migrationNumber ||
                L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.getSettlementLayerChainId() == _l1ChainId(),
            TokenBalanceNotMigratedToGateway(_assetId, savedAssetMigrationNumber, migrationNumber)
        );
    }

    function handleInitiateBaseTokenBridgingOnL2() external view {
        bytes32 baseTokenAssetId = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
        handleInitiateBridgingOnL2(baseTokenAssetId);
    }

    function handleFinalizeBridgingOnL2(bytes32 _assetId, address _tokenAddress) public onlyL2NativeTokenVault {
        _handleFinalizeBridgingOnL2Inner(_assetId, _tokenAddress);
    }

    function _handleFinalizeBridgingOnL2Inner(bytes32 _assetId, address _tokenAddress) internal {
        uint256 migrationNumber = _getMigrationNumber(block.chainid);
        bool allDepositsBeforeMigrationStarted = isL1ToL2DepositProcessed[migrationNumber];
        if (!savedTotalSupply[migrationNumber][_assetId].isSaved && allDepositsBeforeMigrationStarted) {
            savedTotalSupply[migrationNumber][_assetId] = SavedTotalSupply({
                isSaved: true,
                amount: IERC20(_tokenAddress).totalSupply()
            });
        }
    }

    function handleFinalizeBaseTokenBridgingOnL2() external onlyBaseTokenSystemContract {
        bytes32 baseTokenAssetId = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
        if (baseTokenAssetId == bytes32(0)) {
            /// this means we are before the genesis upgrade, where we don't transfer value, so we can skip.
            /// if we don't skip we use incorrect asset id.
            return;
        }
        _handleFinalizeBridgingOnL2Inner(baseTokenAssetId, address(L2_BASE_TOKEN_SYSTEM_CONTRACT));
    }

    function setIsL1ToL2DepositProcessed(uint256 _migrationNumber) external onlyServiceTransactionSender {
        isL1ToL2DepositProcessed[_migrationNumber] = true;
    }

    /*//////////////////////////////////////////////////////////////
                    Chain settlement logs processing on Gateway
    //////////////////////////////////////////////////////////////*/

    /// note we don't process L1 txs here, since we can do that when accepting the tx.
    // kl todo: estimate the txs size, and how much we can handle on GW.
    function processLogsAndMessages(
        ProcessLogsInput calldata _processLogsInputs
    ) external onlyChain(_processLogsInputs.chainId) {
        uint256 msgCount = 0;
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory reconstructedLogsTree = DynamicIncrementalMerkleMemory
            .Bytes32PushTree({
                _nextLeafIndex: 0,
                _sides: new bytes32[](L2_TO_L1_LOGS_MERKLE_TREE_DEPTH),
                _zeros: new bytes32[](L2_TO_L1_LOGS_MERKLE_TREE_DEPTH),
                _sidesLengthMemory: 0,
                _zerosLengthMemory: 0,
                _needsRootRecalculation: false
            }); // todo 100 to const
        // slither-disable-next-line unused-return
        reconstructedLogsTree.setup(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH);
        uint256 logsLength = _processLogsInputs.logs.length;
        bytes32 baseTokenAssetId = _bridgehub().baseTokenAssetId(_processLogsInputs.chainId);
        for (uint256 logCount = 0; logCount < logsLength; ++logCount) {
            L2Log memory log = _processLogsInputs.logs[logCount];
            {
                bytes32 hashedLog = keccak256(
                    // solhint-disable-next-line func-named-parameters
                    abi.encodePacked(log.l2ShardId, log.isService, log.txNumberInBatch, log.sender, log.key, log.value)
                );
                // slither-disable-next-line unused-return
                reconstructedLogsTree.pushLazy(hashedLog);
            }
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

            InteropCall memory interopCall = interopBundle.calls[0];
            uint256 callsLength = interopBundle.calls.length;

            for (uint256 callCount = 1; callCount < callsLength; ++callCount) {
                interopCall = interopBundle.calls[callCount];

                if (interopCall.value > 0) {
                    require(
                        chainBalance[_processLogsInputs.chainId][baseTokenAssetId] >= interopCall.value,
                        InvalidAmount()
                    );
                    chainBalance[_processLogsInputs.chainId][baseTokenAssetId] -= interopCall.value;
                }

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
                (, , address originalToken, uint256 amount, bytes memory erc20Metadata) = DataEncoding
                    .decodeBridgeMintData(transferData);
                // slither-disable-next-line unused-return
                (uint256 tokenOriginalChainId, , , ) = this.parseTokenData(erc20Metadata);
                DataEncoding.assetIdCheck(tokenOriginalChainId, assetId, originalToken);
                if (originToken[assetId] == address(0)) {
                    originToken[assetId] = originalToken;
                    tokenOriginChainId[assetId] = tokenOriginalChainId;
                }

                if (tokenOriginalChainId != fromChainId) {
                    chainBalance[fromChainId][assetId] -= amount;
                }
                if (tokenOriginalChainId != interopBundle.destinationChainId) {
                    chainBalance[interopBundle.destinationChainId][assetId] += amount;
                }
            }
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
    /// @dev This function is permissionless, it does not affect the state.
    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external {
        address tokenAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId);

        if (tokenAddress == address(0)) {
            if (_assetId == L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID()) {
                tokenAddress = address(L2_BASE_TOKEN_SYSTEM_CONTRACT);
            } else {
                return;
            }
        }

        uint256 migrationNumber = _getMigrationNumber(block.chainid);
        uint256 amount;
        {
            SavedTotalSupply memory totalSupply = savedTotalSupply[migrationNumber][_assetId];
            if (!totalSupply.isSaved) {
                amount = IERC20(tokenAddress).totalSupply();
            } else {
                amount = totalSupply.amount;
            }
        }
        uint256 originChainId = L2_NATIVE_TOKEN_VAULT.originChainId(_assetId);
        address originalToken;
        if (originChainId == block.chainid) {
            originalToken = tokenAddress;
        } else if (originChainId != 0) {
            originalToken = IBridgedStandardToken(tokenAddress).originToken();
        } else {
            /// this is the base token case. We don't have the L1 token for it.
            originChainId = L1_CHAIN_ID;
        }

        TokenBalanceMigrationData memory tokenBalanceMigrationData = TokenBalanceMigrationData({
            chainId: block.chainid,
            assetId: _assetId,
            tokenOriginChainId: originChainId,
            amount: amount,
            migrationNumber: migrationNumber,
            originToken: originalToken,
            isL1ToGateway: true
        });
        _sendMigrationDataToL1(tokenBalanceMigrationData);
    }

    /// @notice Migrates the token balance from Gateway to L1.
    /// @dev This function can be called multiple times on the Gateway as it does not have a direct effect.
    /// @dev This function is permissionless, it does not affect the state.
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
            tokenOriginChainId: tokenOriginChainId[_assetId],
            amount: chainBalance[_chainId][_assetId],
            migrationNumber: migrationNumber,
            originToken: originToken[_assetId],
            isL1ToGateway: false
        });

        /// do we want to set this?
        // assetMigrationNumber[_chainId][_assetId] = migrationNumber;
        _sendMigrationDataToL1(tokenBalanceMigrationData);
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

    /*//////////////////////////////////////////////////////////////
                            Helper Functions
    //////////////////////////////////////////////////////////////*/

    function _registerToken(bytes32 _assetId, address _originalToken, uint256 _tokenOriginChainId) internal {
        if (originToken[_assetId] == address(0)) {
            originToken[_assetId] = _originalToken;
            tokenOriginChainId[_assetId] = _tokenOriginChainId;
        }
    }

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
    /// @param _messageRootToAppend The root of the merkle tree of the messages to L1.
    /// @dev The logic of this function depends on the settlement layer as we support
    /// message root aggregation only on non-L1 settlement layers for ease for migration.
    function _appendChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _messageRootToAppend) internal {
        _messageRoot().addChainBatchRoot(_chainId, _batchNumber, _messageRootToAppend);
    }

    function _getMigrationNumber(uint256 _chainId) internal view override returns (uint256) {
        return L2_CHAIN_ASSET_HANDLER.getMigrationNumber(_chainId);
    }
}
