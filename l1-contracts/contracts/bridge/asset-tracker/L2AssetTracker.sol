// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {TOKEN_BALANCE_MIGRATION_DATA_VERSION} from "./IAssetTrackerBase.sol";
import {BUNDLE_IDENTIFIER, BalanceChange, InteropBundle, InteropCall, L2Log, TokenBalanceMigrationData, TxStatus} from "../../common/Messaging.sol";
import {L2_ASSET_ROUTER, L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS, L2_BRIDGEHUB, L2_CHAIN_ASSET_HANDLER, L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_CENTER_ADDR, L2_MESSAGE_ROOT, L2_NATIVE_TOKEN_VAULT, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, MAX_BUILT_IN_CONTRACT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {ChainIdNotRegistered, InvalidInteropCalldata, InvalidMessage, ReconstructionMismatch, Unauthorized} from "../../common/L1ContractErrors.sol";
import {CHAIN_TREE_EMPTY_ENTRY_HASH, IMessageRoot, SHARED_ROOT_TREE_EMPTY_HASH, V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY} from "../../bridgehub/IMessageRoot.sol";
import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOGS_MERKLE_TREE_DEPTH} from "../../common/Config.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {FullMerkleMemory} from "../../common/libraries/FullMerkleMemory.sol";

import {AssetIdNotRegistered, InvalidAmount, InvalidAssetId, InvalidBuiltInContractMessage, InvalidCanonicalTxHash, InvalidInteropChainId, NotEnoughChainBalance, NotMigratedChain, OnlyWithdrawalsAllowedForPreV30Chains, TokenBalanceNotMigratedToGateway, InvalidV30UpgradeChainBatchNumber, InvalidFunctionSignature} from "./AssetTrackerErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {IBridgedStandardToken} from "../BridgedStandardERC20.sol";
import {MessageHashing} from "../../common/libraries/MessageHashing.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {IL1ERC20Bridge} from "../interfaces/IL1ERC20Bridge.sol";
import {IMailboxImpl} from "../../state-transition/chain-interfaces/IMailboxImpl.sol";
import {IAssetTrackerDataEncoding} from "./IAssetTrackerDataEncoding.sol";

struct SavedTotalSupply {
    bool isSaved;
    uint256 amount;
}

contract L2AssetTracker is AssetTrackerBase, IL2AssetTracker {
    using FullMerkleMemory for FullMerkleMemory.FullTree;
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    uint256 public L1_CHAIN_ID;

    mapping(uint256 chainId => mapping(bytes32 canonicalTxHash => BalanceChange balanceChange)) internal balanceChange;

    /// used only on Gateway.
    mapping(bytes32 assetId => address originToken) internal originToken;

    /// used only on Gateway.
    mapping(bytes32 assetId => uint256 originChainId) internal tokenOriginChainId;

    /// used only on Gateway.
    mapping(uint256 chainId => address legacySharedBridgeAddress) internal legacySharedBridgeAddress;

    /// empty messageRoot calculated for specific chain.
    mapping(uint256 chainId => bytes32 emptyMessageRoot) internal emptyMessageRoot;

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

    function setAddresses(uint256 _l1ChainId) external onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
    }
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgehub() internal view override returns (IBridgehub) {
        return L2_BRIDGEHUB;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVault) {
        return L2_NATIVE_TOKEN_VAULT;
    }

    function _messageRoot() internal view override returns (IMessageRoot) {
        return L2_MESSAGE_ROOT;
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external {
        _updateTotalSupplyOnGateway({
            _sourceChainId: L1_CHAIN_ID,
            _destinationChainId: _chainId,
            _tokenOriginChainId: _balanceChange.tokenOriginChainId,
            _assetId: _balanceChange.assetId,
            _amount: _balanceChange.amount
        });
        // we increase the chain balance of the token.
        if (_balanceChange.amount > 0) {
            chainBalance[_chainId][_balanceChange.assetId] += _balanceChange.amount;
        }
        // we increase the chain balance of the base token.
        if (_balanceChange.baseTokenAmount > 0 && _balanceChange.tokenOriginChainId != _chainId) {
            chainBalance[_chainId][_balanceChange.baseTokenAssetId] += _balanceChange.baseTokenAmount;
        }
        if (_tokenCanSkipMigrationOnSettlementLayer(_chainId, _balanceChange.assetId)) {
            _forceSetAssetMigrationNumber(_chainId, _balanceChange.assetId);
        }
        _registerToken(_balanceChange.assetId, _balanceChange.originToken, _balanceChange.tokenOriginChainId);

        /// A malicious chain can cause a collision for the canonical tx hash.
        require(balanceChange[_chainId][_canonicalTxHash].amount == 0, InvalidCanonicalTxHash(_canonicalTxHash));
        // we save the balance change to be able to handle failed deposits.

        balanceChange[_chainId][_canonicalTxHash] = _balanceChange;
    }

    /// @notice This function is called for outgoing bridging from the L2, i.e. L2->L1 withdrawals and outgoing L2->L2 interop.
    function handleInitiateBridgingOnL2(bytes32 _assetId, uint256 _amount, uint256 _tokenOriginChainId) public {
        if (_tokenOriginChainId == block.chainid) {
            // We track the total supply on the origin L2 to make sure the token is not maliciously overflowing the sum of chainBalances.
            totalSupplyAcrossAllChains[_assetId] += _amount;
            return;
        }
        _checkAssetMigrationNumberOnGateway(_assetId);
    }

    function _checkAssetMigrationNumberOnGateway(bytes32 _assetId) internal view {
        uint256 migrationNumber = _getChainMigrationNumber(block.chainid);
        uint256 savedAssetMigrationNumber = assetMigrationNumber[block.chainid][_assetId];
        /// Note we always allow bridging when settling on L1.
        /// On Gateway we require that the tokenBalance be migrated to Gateway from L1,
        /// otherwise withdrawals might fail in the Gateway L2AssetTracker when the chain settles.
        require(
            savedAssetMigrationNumber == migrationNumber ||
                L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.getSettlementLayerChainId() == _l1ChainId(),
            TokenBalanceNotMigratedToGateway(_assetId, savedAssetMigrationNumber, migrationNumber)
        );
    }

    function handleInitiateBaseTokenBridgingOnL2(uint256 _amount) external {
        bytes32 baseTokenAssetId = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
        /// Note the tokenOriginChainId, might not be the L1 chain Id, but the base token is bridged from L1,
        /// and we only use the token origin chain id to increase the totalSupplyAcrossAllChains.
        handleInitiateBridgingOnL2(baseTokenAssetId, _amount, tokenOriginChainId[baseTokenAssetId]);
    }

    function handleFinalizeBridgingOnL2(
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address _tokenAddress
    ) public onlyL2NativeTokenVault {
        _handleFinalizeBridgingOnL2Inner(_assetId, _amount, _tokenOriginChainId, _tokenAddress);
    }

    function _handleFinalizeBridgingOnL2Inner(
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId,
        address //_tokenAddress
    ) internal {
        if (_tokenCanSkipMigrationOnL2(_tokenOriginChainId, _assetId)) {
            _forceSetAssetMigrationNumber(_tokenOriginChainId, _assetId);
        } else {
            /// Deposits are already paused when the chain migrates to GW, however L2->L2 interop is not.
            _checkAssetMigrationNumberOnGateway(_assetId);
        }

        if (_tokenOriginChainId == block.chainid) {
            // We track the total supply on the origin L2 to make sure the token is not maliciously overflowing the sum of chainBalances.
            totalSupplyAcrossAllChains[_assetId] += _amount;
        }
    }

    function handleFinalizeBaseTokenBridgingOnL2(uint256 _amount) external onlyBaseTokenSystemContract {
        bytes32 baseTokenAssetId = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
        if (baseTokenAssetId == bytes32(0)) {
            /// this means we are before the genesis upgrade, where we don't transfer value, so we can skip.
            /// if we don't skip we use incorrect asset id.
            return;
        }
        _handleFinalizeBridgingOnL2Inner(
            baseTokenAssetId,
            _amount,
            L1_CHAIN_ID,
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT)
        );
    }

    function setLegacySharedBridgeAddress(uint256 _chainId, address _legacySharedBridgeAddress) external {
        legacySharedBridgeAddress[_chainId] = _legacySharedBridgeAddress;
    }
    /*//////////////////////////////////////////////////////////////
                    Chain settlement logs processing on Gateway
    //////////////////////////////////////////////////////////////*/

    function processLogsAndMessages(
        ProcessLogsInput calldata _processLogsInputs
    ) external onlyChain(_processLogsInputs.chainId) {
        (, uint32 minor, ) = IZKChain(msg.sender).getSemverProtocolVersion();
        /// If a chain is pre v30, we only allow withdrawals, and don't keep track of chainBalance.
        bool onlyWithdrawals = minor < 30;
        /// We check that the chain has not upgraded to V30 for onlyWithdrawals case.
        require(
            !onlyWithdrawals ||
                L2_MESSAGE_ROOT.v30UpgradeChainBatchNumber(_processLogsInputs.chainId) ==
                V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY,
            InvalidV30UpgradeChainBatchNumber(_processLogsInputs.chainId)
        );

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
                if (log.value == bytes32(uint256(TxStatus.Failure))) {
                    _handlePotentialFailedDeposit(_processLogsInputs.chainId, log.key);
                }
                continue;
            } else if (log.sender == L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR) {
                ++msgCount;
                bytes memory message = _processLogsInputs.messages[msgCount - 1];

                if (log.value != keccak256(message)) {
                    revert InvalidMessage();
                }

                if (log.key == bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR)))) {
                    require(!onlyWithdrawals, OnlyWithdrawalsAllowedForPreV30Chains());
                    _handleInteropMessage(_processLogsInputs.chainId, message, baseTokenAssetId);
                } else if (log.key == bytes32(uint256(uint160(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR)))) {
                    _handleBaseTokenSystemContractMessage(_processLogsInputs.chainId, baseTokenAssetId, message);
                } else if (log.key == bytes32(uint256(uint160(L2_ASSET_ROUTER_ADDR)))) {
                    _handleAssetRouterMessage(_processLogsInputs.chainId, message);
                } else if (log.key == bytes32(uint256(uint160(L2_ASSET_TRACKER_ADDR)))) {
                    _checkAssetTrackerMessageSelector(message);
                } else if (uint256(log.key) <= MAX_BUILT_IN_CONTRACT_ADDR) {
                    revert InvalidBuiltInContractMessage(logCount, msgCount - 1, log.key);
                } else {
                    address legacySharedBridge = legacySharedBridgeAddress[block.chainid];
                    if (log.key == bytes32(uint256(uint160(legacySharedBridge))) && legacySharedBridge != address(0)) {
                        _handleLegacySharedBridgeMessage(_processLogsInputs.chainId, message);
                    }
                }
            }
        }
        reconstructedLogsTree.extendUntilEnd();
        bytes32 localLogsRootHash = reconstructedLogsTree.root();

        // bytes32 emptyMessageRootForChain =
        _getEmptyMessageRoot(_processLogsInputs.chainId);
        /// kl todo: fix this alongside FullMerkleMemory
        // require(_processLogsInputs.messageRoot == emptyMessageRootForChain, InvalidEmptyMessageRoot(emptyMessageRootForChain, _processLogsInputs.messageRoot));
        bytes32 chainBatchRootHash = keccak256(bytes.concat(localLogsRootHash, _processLogsInputs.messageRoot));

        if (chainBatchRootHash != _processLogsInputs.chainBatchRoot) {
            revert ReconstructionMismatch(chainBatchRootHash, _processLogsInputs.chainBatchRoot);
        }

        _appendChainBatchRoot(_processLogsInputs.chainId, _processLogsInputs.batchNumber, chainBatchRootHash);
    }

    function _getEmptyMessageRoot(uint256 _chainId) internal returns (bytes32) {
        bytes32 savedEmptyMessageRoot = emptyMessageRoot[_chainId];
        if (savedEmptyMessageRoot != bytes32(0)) {
            return savedEmptyMessageRoot;
        }
        FullMerkleMemory.FullTree memory sharedTree;
        sharedTree.createTree(2);
        sharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);

        DynamicIncrementalMerkleMemory.Bytes32PushTree memory chainTree;
        chainTree.createTree(1);
        bytes32 initialChainTreeHash = chainTree.setup(CHAIN_TREE_EMPTY_ENTRY_HASH);
        bytes32 leafHash = MessageHashing.chainIdLeafHash(initialChainTreeHash, _chainId);
        return bytes32(leafHash); // kl todo fix
        // bytes32 emptyMessageRootCalculated = sharedTree.pushNewLeaf(leafHash);

        // emptyMessageRoot[_chainId] = emptyMessageRootCalculated;
        // return emptyMessageRootCalculated;
    }

    /// @notice Handles potential failed deposits. Not all L1->L2 txs are deposits.
    function _handlePotentialFailedDeposit(uint256 _chainId, bytes32 _canonicalTxHash) internal {
        BalanceChange memory savedBalanceChange = balanceChange[_chainId][_canonicalTxHash];
        /// Note we handle failedDeposits here for deposits that do not go through GW during chainMigration,
        /// because they were initiated when the chain settles on L1, however the failedDeposit L2->L1 message goes through GW.
        /// Here we do not need to decrement the chainBalance, since the chainBalance was added to the chain's chainBalance on L1,
        /// and never migrated to the GW's chainBalance, since it never increments the totalSupply since the L2 txs fails.
        if (savedBalanceChange.amount > 0 && savedBalanceChange.tokenOriginChainId != _chainId) {
            chainBalance[_chainId][savedBalanceChange.assetId] -= savedBalanceChange.amount;
        }
        /// Note the base token is never native to the chain as of V30.
        if (savedBalanceChange.baseTokenAmount > 0) {
            chainBalance[_chainId][savedBalanceChange.baseTokenAssetId] -= savedBalanceChange.baseTokenAmount;
        }
    }

    function _handleInteropMessage(uint256 _chainId, bytes memory _message, bytes32 _baseTokenAssetId) internal {
        if (_message[0] != BUNDLE_IDENTIFIER) {
            // This should not be possible in V30. In V31 this will be a trigger.
            return;
        }

        InteropBundle memory interopBundle = this.parseInteropBundle(_message);

        InteropCall memory interopCall;
        uint256 callsLength = interopBundle.calls.length;

        for (uint256 callCount = 0; callCount < callsLength; ++callCount) {
            interopCall = interopBundle.calls[callCount];

            if (interopCall.value > 0) {
                require(chainBalance[_chainId][_baseTokenAssetId] >= interopCall.value, InvalidAmount());
                chainBalance[_chainId][_baseTokenAssetId] -= interopCall.value;
            }

            // e.g. for direct calls we just skip
            if (interopCall.from != L2_ASSET_ROUTER_ADDR) {
                continue;
            }

            if (bytes4(interopCall.data) != IAssetRouterBase.finalizeDeposit.selector) {
                revert InvalidInteropCalldata(bytes4(interopCall.data));
            }
            (uint256 fromChainId, bytes32 assetId, bytes memory transferData) = this.parseInteropCall(interopCall.data);
            require(_chainId == fromChainId, InvalidInteropChainId(fromChainId, interopBundle.destinationChainId));

            _handleAssetRouterMessageInner(_chainId, interopBundle.destinationChainId, assetId, transferData);
        }
    }

    /// @notice L2->L1 withdrawals go through the L2AssetRouter directly.
    function _handleAssetRouterMessage(uint256 _chainId, bytes memory _message) internal {
        (bytes4 functionSignature, , bytes32 assetId, bytes memory transferData) = DataEncoding
            .decodeAssetRouterFinalizeDepositData(_message);
        require(
            functionSignature == IAssetRouterBase.finalizeDeposit.selector,
            InvalidFunctionSignature(functionSignature)
        );
        _handleAssetRouterMessageInner(_chainId, L1_CHAIN_ID, assetId, transferData);
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
        bytes memory _transferData
    ) internal {
        // slither-disable-next-line unused-return
        (, , address originalToken, uint256 amount, bytes memory erc20Metadata) = DataEncoding.decodeBridgeMintData(
            _transferData
        );
        // slither-disable-next-line unused-return
        (uint256 tokenOriginalChainId, , , ) = this.parseTokenData(erc20Metadata);
        DataEncoding.assetIdCheck(tokenOriginalChainId, _assetId, originalToken);
        if (originToken[_assetId] == address(0)) {
            originToken[_assetId] = originalToken;
            tokenOriginChainId[_assetId] = tokenOriginalChainId;
        }

        _handleChainBalanceChangeOnGateway({
            _sourceChainId: _sourceChainId,
            _destinationChainId: _destinationChainId,
            _tokenOriginalChainId: tokenOriginalChainId,
            _assetId: _assetId,
            _amount: amount
        });

        _updateTotalSupplyOnGateway({
            _sourceChainId: _sourceChainId,
            _destinationChainId: _destinationChainId,
            _tokenOriginChainId: tokenOriginalChainId,
            _assetId: _assetId,
            _amount: amount
        });
    }

    function _handleChainBalanceChangeOnGateway(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        uint256 _tokenOriginalChainId,
        bytes32 _assetId,
        uint256 _amount
    ) internal {
        if (_tokenOriginalChainId != _sourceChainId && _amount > 0) {
            require(
                chainBalance[_sourceChainId][_assetId] >= _amount,
                NotEnoughChainBalance(_sourceChainId, _assetId, _amount)
            );
            chainBalance[_sourceChainId][_assetId] -= _amount;
        }
        if (_tokenOriginalChainId != _destinationChainId && _amount > 0) {
            chainBalance[_destinationChainId][_assetId] += _amount;
        }
    }

    function _handleLegacySharedBridgeMessage(uint256 _chainId, bytes memory _message) internal {
        (bytes4 functionSignature, address l1Token, bytes memory transferData) = DataEncoding
            .decodeLegacyFinalizeWithdrawalData(_message);
        require(
            functionSignature == IL1ERC20Bridge.finalizeWithdrawal.selector,
            InvalidFunctionSignature(functionSignature)
        );
        /// The legacy shared bridge message is only for L1 tokens on legacy chains where the legacy L2 shared bridge is deployed.
        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);

        _handleAssetRouterMessageInner(_chainId, L1_CHAIN_ID, expectedAssetId, transferData);
    }

    /// @notice L2->L1 base token withdrawals go through the L2BaseTokenSystemContract directly.
    function _handleBaseTokenSystemContractMessage(
        uint256 _chainId,
        bytes32 _baseTokenAssetId,
        bytes memory _message
    ) internal {
        (bytes4 functionSignature, , uint256 amount) = DataEncoding.decodeBaseTokenFinalizeWithdrawalData(_message);
        require(
            functionSignature == IMailboxImpl.finalizeEthWithdrawal.selector,
            InvalidFunctionSignature(functionSignature)
        );
        chainBalance[_chainId][_baseTokenAssetId] -= amount;
        _updateTotalSupplyOnGateway({
            _sourceChainId: _chainId,
            _destinationChainId: L1_CHAIN_ID,
            _tokenOriginChainId: tokenOriginChainId[_baseTokenAssetId],
            _assetId: _baseTokenAssetId,
            _amount: amount
        });
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

    /// we track the total supply on the gateway to make sure the chain and token are not maliciously overflowing the sum of chainBalances.
    function _updateTotalSupplyOnGateway(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        uint256 _tokenOriginChainId,
        bytes32 _assetId,
        uint256 _amount
    ) internal {
        if (_tokenOriginChainId == _sourceChainId) {
            totalSupplyAcrossAllChains[_assetId] += _amount;
        } else if (_tokenOriginChainId == _destinationChainId) {
            totalSupplyAcrossAllChains[_assetId] -= _amount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    Gateway related token balance migration 
    //////////////////////////////////////////////////////////////*/

    /// @notice Migrates the token balance from L2 to L1.
    /// @dev This function can be called multiple times on the chain it does not have a direct effect.
    /// @dev This function is permissionless, it does not affect the state.
    function initiateL1ToGatewayMigrationOnL2(bytes32 _assetId) external {
        address tokenAddress = _tryGetTokenAddress(_assetId);

        uint256 originChainId = L2_NATIVE_TOKEN_VAULT.originChainId(_assetId);
        address originalToken;
        if (originChainId == block.chainid) {
            originalToken = tokenAddress;
        } else if (originChainId != 0) {
            originalToken = IBridgedStandardToken(tokenAddress).originToken();
        } else {
            /// this is the base token case. We can set the L1 chain id here, we don't store the real origin chainId.
            originChainId = L1_CHAIN_ID;
        }
        uint256 migrationNumber = _getChainMigrationNumber(block.chainid);
        uint256 amount = IERC20(tokenAddress).totalSupply();

        TokenBalanceMigrationData memory tokenBalanceMigrationData = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
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

        uint256 migrationNumber = _getChainMigrationNumber(_chainId);
        require(assetMigrationNumber[_chainId][_assetId] < migrationNumber, InvalidAssetId(_assetId));

        TokenBalanceMigrationData memory tokenBalanceMigrationData = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: _chainId,
            assetId: _assetId,
            tokenOriginChainId: tokenOriginChainId[_assetId],
            amount: chainBalance[_chainId][_assetId],
            migrationNumber: migrationNumber,
            originToken: originToken[_assetId],
            isL1ToGateway: false
        });

        _sendMigrationDataToL1(tokenBalanceMigrationData);
    }

    function confirmMigrationOnGateway(TokenBalanceMigrationData calldata data) external {
        //onlyServiceTransactionSender {
        assetMigrationNumber[data.chainId][data.assetId] = data.migrationNumber;
        if (data.isL1ToGateway) {
            /// In this case the balance might never have been migrated back to L1.
            chainBalance[data.chainId][data.assetId] += data.amount;
            totalSupplyAcrossAllChains[data.assetId] += data.amount;
        } else {
            require(data.amount == chainBalance[data.chainId][data.assetId], InvalidAmount());
            chainBalance[data.chainId][data.assetId] = 0;
            totalSupplyAcrossAllChains[data.assetId] -= data.amount;
        }
    }

    function confirmMigrationOnL2(TokenBalanceMigrationData calldata data) external {
        //onlyServiceTransactionSender {
        assetMigrationNumber[block.chainid][data.assetId] = data.migrationNumber;
    }

    function _sendMigrationDataToL1(TokenBalanceMigrationData memory data) internal {
        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            abi.encodeCall(IAssetTrackerDataEncoding.receiveMigrationOnL1, data)
        );
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

    function _tokenCanSkipMigrationOnL2(uint256 _chainId, bytes32 _assetId) internal view returns (bool) {
        uint256 savedAssetMigrationNumber = assetMigrationNumber[_chainId][_assetId];
        address tokenAddress = _tryGetTokenAddress(_assetId);
        uint256 amount = IERC20(tokenAddress).totalSupply();

        return savedAssetMigrationNumber == 0 && amount == 0;
    }

    function _tryGetTokenAddress(bytes32 _assetId) internal view returns (address tokenAddress) {
        tokenAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId);

        if (tokenAddress == address(0)) {
            if (_assetId == L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID()) {
                tokenAddress = address(L2_BASE_TOKEN_SYSTEM_CONTRACT);
            } else {
                revert AssetIdNotRegistered(_assetId);
            }
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

    function _getChainMigrationNumber(uint256 _chainId) internal view override returns (uint256) {
        return L2_CHAIN_ASSET_HANDLER.getMigrationNumber(_chainId);
    }
}
