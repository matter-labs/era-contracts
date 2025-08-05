// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {TokenBalanceMigrationData} from "./IAssetTrackerBase.sol";
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, L2Log, TxStatus} from "../../common/Messaging.sol";
import {L2_ASSET_ROUTER_ADDR, L2_BOOTLOADER_ADDRESS, L2_BRIDGEHUB, L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {ChainIdNotRegistered, InvalidInteropCalldata, InvalidMessage, ReconstructionMismatch, Unauthorized} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOGS_MERKLE_TREE_DEPTH} from "../../common/Config.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";

import {InvalidAmount, InvalidAssetId, InvalidAssetMigrationNumber, NotMigratedChain} from "./AssetTrackerErrors.sol";
import {AssetTrackerBase, BalanceChange} from "./AssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {IBridgedStandardToken} from "../BridgedStandardERC20.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

contract L2AssetTracker is AssetTrackerBase, IL2AssetTracker {
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    uint256 public L1_CHAIN_ID;

    IBridgehub public BRIDGE_HUB;

    INativeTokenVault public NATIVE_TOKEN_VAULT;

    IMessageRoot public MESSAGE_ROOT;


    mapping(uint256 migrationNumber => mapping(bytes32 assetId => uint256 totalSupply)) internal totalSupply;

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

    function setAddresses(
        uint256 _l1ChainId,
        address _bridgeHub,
        address,
        address _nativeTokenVault,
        address _messageRoot
    ) external onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
        BRIDGE_HUB = IBridgehub(_bridgeHub);
        NATIVE_TOKEN_VAULT = INativeTokenVault(_nativeTokenVault);
        MESSAGE_ROOT = IMessageRoot(_messageRoot);
    }
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgeHub() internal view override returns (IBridgehub) {
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
        /// kl todo should we save tokenOriginChainId here?
        /// It is only needed for migration back to L1 when the token is not L1 registered. But these tokens are, so? 


        /// A malicious chain can cause a collision for the canonical tx hash.
        /// This will only decrease the chain's balance, so it is not a security issue.
        balanceChange[_chainId][_canonicalTxHash] = _balanceChange;
    }

    function handleInitiateBridgingOnL2(bytes32 _assetId) external view {
        uint256 migrationNumber = _getMigrationNumber(block.chainid);
        uint256 savedAssetMigrationNumber = assetMigrationNumber[block.chainid][_assetId];
        require(
            savedAssetMigrationNumber == migrationNumber ||
                L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.getSettlementLayerChainId() == _l1ChainId(),
            InvalidAssetMigrationNumber(savedAssetMigrationNumber, migrationNumber)
        );
    }

    function handleFinalizeBridgingOnL2(bytes32 _assetId) external {
        uint256 migrationNumber = _getMigrationNumber(block.chainid);
        if (totalSupply[migrationNumber][_assetId] == 0) {
            totalSupply[migrationNumber][_assetId] = IERC20(L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId)).totalSupply();
        }
    }

    /*//////////////////////////////////////////////////////////////
                    Chain settlement logs processing on Gateway
    //////////////////////////////////////////////////////////////*/

    /// note we don't process L1 txs here, since we can do that when accepting the tx.
    // kl todo: estimate the txs size, and how much we can handle on GW.
    function processLogsAndMessages(ProcessLogsInput calldata _processLogsInputs) external {
        /// add onlyChain(processLogsInput.chainId)
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
                (, , address originalToken, uint256 amount, bytes memory erc20Metadata) = DataEncoding.decodeBridgeMintData(transferData);
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
            return;
        }

        uint256 migrationNumber = _getMigrationNumber(block.chainid);
        uint256 amount;
        {
            uint256 savedTotalSupply = totalSupply[migrationNumber][_assetId];
            if (savedTotalSupply == 0) {
                amount = IERC20(tokenAddress).totalSupply();
            } else {
                amount = savedTotalSupply;
            }
        }
        uint256 originChainId = L2_NATIVE_TOKEN_VAULT.originChainId(_assetId);
        address originalToken;
        if (originChainId == block.chainid) {
            originalToken = tokenAddress;
        } else {
            originalToken = IBridgedStandardToken(tokenAddress).originToken();
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
}
