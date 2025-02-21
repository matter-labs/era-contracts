// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAssetTracker} from "./IAssetTracker.sol";
import {WritePriorityOpParams, L2CanonicalTransaction, L2Message, L2Log, TxStatus, BridgehubL2TransactionRequest} from "../../common/Messaging.sol";
import {L2_INTEROP_CENTER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {InteropBundle, InteropCall} from "../../common/Messaging.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {OriginChainIdNotFound, Unauthorized, ZeroAddress, NoFundsTransferred, InsufficientChainBalance, WithdrawFailed} from "../../common/L1ContractErrors.sol";

error InvalidMessage();
contract AssetTracker is IAssetTracker {
    IAssetRouterBase public immutable ASSET_ROUTER;

    INativeTokenVault public immutable NATIVE_TOKEN_VAULT;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;

    mapping(uint256 chainId => mapping(bytes32 assetId => bool isMinter)) public isMinterChain;

    constructor(address _assetRouter, address _nativeTokenVault) {
        ASSET_ROUTER = IAssetRouterBase(_assetRouter);
        NATIVE_TOKEN_VAULT = INativeTokenVault(_nativeTokenVault);
    }

    function initialize() external {
        // TODO: implement
    }

    function migrateChainBalance(uint256 _chainId, bytes32 _assetId) external {
        // TODO: implement
    }

    function handleChainBalanceIncrease(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external {
        chainBalance[_chainId][_assetId] += _amount;
    }

    function handleChainBalanceDecrease(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external {
        // Check that the chain has sufficient balance
        if (chainBalance[_chainId][_assetId] < _amount) {
            revert InsufficientChainBalance();
        }
        chainBalance[_chainId][_assetId] -= _amount;
    }

    /// note we don't process L1 txs here, since we can do that when accepting the tx.
    function processLogsAndMessages(L2Log[] calldata _logs, bytes[] calldata _messages, bytes32) external {
        uint256 msgCount = 0;
        for (uint256 logCount = 0; logCount < _logs.length; logCount++) {
            L2Log memory log = _logs[logCount];
            if (
                log.sender != L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR ||
                log.key != bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR)))
            ) {
                continue;
            }
            bytes memory message = _messages[msgCount];
            if (log.value != keccak256(message)) {
                revert InvalidMessage();
            }

            InteropBundle memory interopBundle = abi.decode(message, (InteropBundle));

            // handle msg.value call separately
            InteropCall memory interopCall = interopBundle.calls[0];
            for (uint256 callCount = 1; callCount < interopBundle.calls.length; callCount++) {
                if (bytes4(interopCall.data) != IAssetRouterBase.finalizeDeposit.selector) {
                    revert InvalidMessage();
                }
                (uint256 fromChainId, bytes32 assetId, bytes memory transferData) = this.parseInteropCall(
                    interopCall.data
                );
                (, , , uint256 amount, ) = DataEncoding.decodeBridgeMintData(transferData);
                if (!isMinterChain[fromChainId][assetId]) {
                    chainBalance[fromChainId][assetId] -= amount;
                }
                if (!isMinterChain[interopBundle.destinationChainId][assetId]) {
                    chainBalance[interopBundle.destinationChainId][assetId] += amount;
                }
            }

            // kl todo add L1<>L2 messaging here
            // kl todo add change minter role here
            msgCount++;
        }
    }

    function parseInteropCall(
        bytes calldata _callData
    ) external pure returns (uint256 fromChainId, bytes32 assetId, bytes memory transferData) {
        (fromChainId, assetId, transferData) = abi.decode(_callData[4:], (uint256, bytes32, bytes));
    }
}
