// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;


import {L2_BRIDGEHUB_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {FinalizeL1DepositParams} from "../bridge/interfaces/IL1Nullifier.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The L1InteropHandler contract is responsible for handling interops from L2.
contract L1InteropHandler {

    address public l2InteropCenterAddress;

    address public l1BridgehubAddress;

    function receiveInteropFromL2(
        FinalizeL1DepositParams memory _tokenWithdrawalParams,
        FinalizeL1DepositParams memory _bundleWithdrawalParams
    ) external returns (address l1Receiver, address l1Token, uint256 amount) {
        (l1Receiver, l1Token, amount) = _parseL2WithdrawalMessage(_tokenWithdrawalParams.message);

        // deploy shadow account if needed
        address shadowAccount = _deployShadowAccount(_tokenWithdrawalParams.l2Sender);

        // execute bundle withdrawal
        _executeBundleWithdrawal(_bundleWithdrawalParams);
    }

        /// @notice Verifies the validity of a withdrawal message from L2 and returns withdrawal details.
    /// @param _finalizeWithdrawalParams The structure that holds all necessary data to finalize withdrawal
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdawal.
    function _verifyWithdrawal(
        FinalizeL1DepositParams memory _finalizeWithdrawalParams,
        bool overrideL2Sender
    ) internal returns (bytes32 assetId, bytes memory transferData) {
        (assetId, transferData) = _parseL2WithdrawalMessage(
            _finalizeWithdrawalParams.chainId,
            _finalizeWithdrawalParams.message
        );
        L2Message memory l2ToL1Message;
        {
            address l2Sender = _finalizeWithdrawalParams.l2Sender;
            bool baseTokenWithdrawal = (assetId == BRIDGE_HUB.baseTokenAssetId(_finalizeWithdrawalParams.chainId));

            bool isL2SenderCorrect = l2Sender == L2_ASSET_ROUTER_ADDR ||
                l2Sender == L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR ||
                l2Sender == __DEPRECATED_l2BridgeAddress[_finalizeWithdrawalParams.chainId];
            if (!isL2SenderCorrect) {
                revert WrongL2Sender(l2Sender);
            }

            l2ToL1Message = L2Message({
                txNumberInBatch: _finalizeWithdrawalParams.l2TxNumberInBatch,
                sender: baseTokenWithdrawal ? L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR : l2Sender,
                data: _finalizeWithdrawalParams.message
            });
        }

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

        /// @notice Parses the withdrawal message and returns withdrawal details.
    /// @dev Currently, 3 different encoding versions are supported: legacy mailbox withdrawal, ERC20 bridge withdrawal,
    /// @dev and the latest version supported by shared bridge. Selectors are used for versioning.
    /// @param _chainId The ZK chain ID.
    /// @param _l2ToL1message The encoded L2 -> L1 message.
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdawal.
    function _parseL2WithdrawalMessage(
        uint256 _chainId,
        bytes memory _l2ToL1message
    ) internal returns (bytes32 assetId, bytes memory transferData) {
        // Please note that there are three versions of the message:
        // 1. The message that is sent from `L2BaseToken` to withdraw base token.
        // 2. The message that is sent from L2 Legacy Shared Bridge to withdraw ERC20 tokens or base token.
        // 3. The message that is sent from L2 Asset Router to withdraw ERC20 tokens or base token.

        uint256 amount;
        address l1Receiver;

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) == IMailboxImpl.finalizeEthWithdrawal.selector) {
            // The data is expected to be at least 56 bytes long.
            if (_l2ToL1message.length < 56) {
                revert L2WithdrawalMessageWrongLength(_l2ToL1message.length);
            }
            // this message is a base token withdrawal
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            // slither-disable-next-line unused-return
            (amount, ) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            assetId = BRIDGE_HUB.baseTokenAssetId(_chainId);
            transferData = DataEncoding.encodeBridgeMintData({
                _originalCaller: address(0),
                _remoteReceiver: l1Receiver,
                // Note, that `assetId` could belong to a token native to an L2, and so
                // the logic for determining the correct origin token address will be complex.
                // It is expected that this value won't be used in the NativeTokenVault and so providing
                // any value is acceptable here.
                _originToken: address(0),
                _amount: amount,
                _erc20Metadata: new bytes(0)
            });
        } else if (bytes4(functionSignature) == IL1ERC20Bridge.finalizeWithdrawal.selector) {
            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            if (_l2ToL1message.length != 76) {
                revert L2WithdrawalMessageWrongLength(_l2ToL1message.length);
            }
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            // We use the IL1ERC20Bridge for backward compatibility with old withdrawals.
            address l1Token;
            (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            // slither-disable-next-line unused-return
            (amount, ) = UnsafeBytes.readUint256(_l2ToL1message, offset);

            assetId = l1NativeTokenVault.ensureTokenIsRegistered(l1Token);
            bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(block.chainid, l1Token);
            // This method is only expected to use L1-based tokens.
            if (assetId != expectedAssetId) {
                revert TokenNotLegacy();
            }
            transferData = DataEncoding.encodeBridgeMintData({
                _originalCaller: address(0),
                _remoteReceiver: l1Receiver,
                _originToken: l1Token,
                _amount: amount,
                _erc20Metadata: new bytes(0)
            });
        } else if (bytes4(functionSignature) == IAssetRouterBase.finalizeDeposit.selector) {
            // The data is expected to be at least 68 bytes long to contain assetId.
            if (_l2ToL1message.length < 68) {
                revert WrongMsgLength(68, _l2ToL1message.length);
            }
            // slither-disable-next-line unused-return
            (, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset); // originChainId, not used for L2->L1 txs
            (assetId, offset) = UnsafeBytes.readBytes32(_l2ToL1message, offset);
            transferData = UnsafeBytes.readRemainingBytes(_l2ToL1message, offset);
        } else {
            revert InvalidSelector(bytes4(functionSignature));
        }
    }

}