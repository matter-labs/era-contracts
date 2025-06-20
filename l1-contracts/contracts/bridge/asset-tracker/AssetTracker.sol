// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {IAssetTracker} from "./IAssetTracker.sol";
import {BUNDLE_IDENTIFIER, InteropBundle, InteropCall, L2Log, L2Message} from "../../common/Messaging.sol";
import {L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_INTEROP_CENTER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_NATIVE_TOKEN_VAULT} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {InsufficientChainBalanceAssetTracker, InvalidInteropCalldata, InvalidMessage, InvalidProof, ReconstructionMismatch, Unauthorized} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOGS_MERKLE_TREE_DEPTH} from "../../common/Config.sol";
import {AssetHandlerModifiers} from "../interfaces/AssetHandlerModifiers.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {FinalizeL1DepositParams} from "../../bridge/interfaces/IL1Nullifier.sol";

import {TransientPrimitivesLib} from "../../common/libraries/TransientPrimitves/TransientPrimitives.sol";

error AlreadyMigrated();

contract AssetTracker is IAssetTracker, Ownable2StepUpgradeable, AssetHandlerModifiers {
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    uint256 public immutable L1_CHAIN_ID;

    IBridgehub public immutable BRIDGE_HUB;

    IAssetRouterBase public immutable ASSET_ROUTER;

    INativeTokenVault public immutable NATIVE_TOKEN_VAULT;

    IMessageRoot public immutable MESSAGE_ROOT;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    /// @dev For minter chains, the balance is 0.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;

    mapping(uint256 chainId => mapping(bytes32 assetId => bool isMinter)) public isMinterChain;
    mapping(bytes32 assetId => uint256 numberOfSettlingMintingChains) public numberOfSettlingMintingChains;

    // for now, should be replaced by isMinterChain.
    mapping(bytes32 assetId => uint256 originChainId) public originChainId;

    constructor(
        uint256 _l1ChainId,
        address _bridgeHub,
        address _assetRouter,
        address _nativeTokenVault,
        address _messageRoot
    ) {
        L1_CHAIN_ID = _l1ChainId;
        BRIDGE_HUB = IBridgehub(_bridgeHub);
        ASSET_ROUTER = IAssetRouterBase(_assetRouter);
        NATIVE_TOKEN_VAULT = INativeTokenVault(_nativeTokenVault);
        MESSAGE_ROOT = IMessageRoot(_messageRoot);
    }

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyAssetRouter() {
        require(msg.sender == address(ASSET_ROUTER), Unauthorized(msg.sender));
        _;
    }

    function initialize() external {
        // TODO: implement
    }

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
                            Token balance migration 
    //////////////////////////////////////////////////////////////*/

    // // slither-disable-next-line locked-ether
    // function bridgeMint(
    //     uint256 _originSettlementChainId,
    //     bytes32 _assetId,
    //     bytes calldata _data
    // ) external payable requireZeroValue(msg.value) onlyAssetRouter {
    //     (
    //         uint256 chainId,
    //         bytes32 assetId,
    //         uint256 amount,
    //         bool migratingChainIsMinter,
    //         bool isSLStillMinter,
    //         uint256 newSLBalance
    //     ) = DataEncoding.decodeAssetTrackerData(_data);
    //     chainBalance[chainId][assetId] += amount;
    //     isMinterChain[chainId][assetId] = migratingChainIsMinter;
    //     numberOfSettlingMintingChains[assetId] += migratingChainIsMinter ? 1 : 0;
    //     if (migratingChainIsMinter && block.chainid == L1_CHAIN_ID) {
    //         if (!isSLStillMinter) {
    //             isMinterChain[_originSettlementChainId][_assetId] = false;
    //             chainBalance[_originSettlementChainId][_assetId] = newSLBalance;
    //         }
    //     }
    // }

    // // slither-disable-next-line locked-ether
    // function bridgeBurn(
    //     uint256 _settlementChainId,
    //     uint256,
    //     bytes32, // _assetId todo add check on it.
    //     address,
    //     bytes calldata _data
    // ) external payable requireZeroValue(msg.value) onlyAssetRouter returns (bytes memory _bridgeMintData) {
    //     if (!BRIDGE_HUB.whitelistedSettlementLayers(_settlementChainId)) {
    //         revert SLNotWhitelisted();
    //     }
    //     (uint256 chainId, bytes32 assetId) = abi.decode(_data, (uint256, bytes32));
    //     // kl todo add assetId check.
    //     // if (_assetId != ) {
    //     //     revert IncorrectChainAssetId(_assetId, (chainId));
    //     // }
    //     if (BRIDGE_HUB.settlementLayer(chainId) != _settlementChainId) {
    //         revert NotCurrentSettlementLayer();
    //     }
    //     bool migratingChainIsMinter = isMinterChain[chainId][assetId];
    //     uint256 amount = chainBalance[chainId][assetId];
    //     if (amount == 0 && !migratingChainIsMinter) {
    //         // we already migrated or there is nothing to migrate
    //         revert AlreadyMigrated();
    //     }
    //     chainBalance[chainId][assetId] = 0;
    //     isMinterChain[chainId][assetId] = false;
    //     uint256 newSLBalance = 0;

    //     if (migratingChainIsMinter) {
    //         --numberOfSettlingMintingChains[assetId];
    //         if (block.chainid == L1_CHAIN_ID) {
    //             isMinterChain[_settlementChainId][assetId] = true;
    //         } else {
    //             if (numberOfSettlingMintingChains[assetId] == 0) {
    //                 // we need to calculate the current balance of this chain, the sum of all the balances on it.
    //                 uint256[] memory zkChainIds = BRIDGE_HUB.getAllZKChainChainIDs();
    //                 uint256 zkChainIdsLength = zkChainIds.length;
    //                 for (uint256 i = 0; i < zkChainIdsLength; ++i) {
    //                     if (BRIDGE_HUB.settlementLayer(zkChainIds[i]) == block.chainid) {
    //                         newSLBalance += chainBalance[zkChainIds[i]][assetId];
    //                     }
    //                 }
    //             }
    //         }
    //     } else if (!isMinterChain[_settlementChainId][assetId] && block.chainid == L1_CHAIN_ID) {
    //         // We only care about the chainBalance if the SL is not a minter.
    //         // On GW we don't care about the L1 chainBalance.
    //         chainBalance[_settlementChainId][assetId] += amount;
    //     }

    //     return
    //         DataEncoding.encodeAssetTrackerData({
    //             _chainId: chainId,
    //             _assetId: assetId,
    //             _amount: amount,
    //             _migratingChainIsMinter: migratingChainIsMinter,
    //             _hasSettlingMintingChains: numberOfSettlingMintingChains[assetId] > 0,
    //             _newSLBalance: newSLBalance
    //         });
    // }

    /// @notice Migrates the token balance from L2 to L1.
    function migrateTokenBalanceFromL2(bytes32 _assetId) external {
        address tokenAddress = L2_NATIVE_TOKEN_VAULT.tokenAddress(_assetId);

        uint256 amount = IERC20(tokenAddress).totalSupply();

        uint256 migrationNumber = 0; // L2_INTEROP_CENTER.migrationNumber();

        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            _encodeTokenBalanceMigrationData(block.chainid, _assetId, amount, migrationNumber)
        );
    }

    function receiveMigrationOnGateway(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        _proveMessageInclusion(_finalizeWithdrawalParams);

        // solhint-disable-next-line no-unused-vars
        (uint256 chainId, bytes32 assetId, uint256 amount, uint256 migrationNumber) = abi.decode(
            _finalizeWithdrawalParams.message,
            (uint256, bytes32, uint256, uint256)
        );
        /// Add migration number check here.
        chainBalance[chainId][assetId] += amount;

        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(_finalizeWithdrawalParams.message);
    }

    function receiveMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        _proveMessageInclusion(_finalizeWithdrawalParams);

        (uint256 chainId, bytes32 assetId, uint256 amount, uint256 migrationNumber) = _decodeTokenBalanceMigrationData(
            _finalizeWithdrawalParams.message
        );
        chainBalance[chainId][assetId] -= amount;

        _sendConfirmationToL2(chainId, assetId, amount, migrationNumber);
    }

    function confirmMigrationOnL2(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _migrationNumber
    ) external {}

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

    function _sendConfirmationToL2(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _migrationNumber
    ) internal {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(
            L2_ASSET_TRACKER_ADDR,
            abi.encodeCall(this.confirmMigrationOnL2, (_chainId, _assetId, _amount, _migrationNumber))
        );
    }

    function _encodeTokenBalanceMigrationData(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _migrationNumber
    ) internal pure returns (bytes memory) {
        return abi.encode(_chainId, _assetId, _amount, _migrationNumber);
    }

    function _decodeTokenBalanceMigrationData(
        bytes calldata _data
    ) internal pure returns (uint256 chainId, bytes32 assetId, uint256 amount, uint256 migrationNumber) {
        (chainId, assetId, amount, migrationNumber) = abi.decode(_data, (uint256, bytes32, uint256, uint256));
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
