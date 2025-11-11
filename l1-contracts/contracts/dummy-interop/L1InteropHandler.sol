// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;


import {L2_BRIDGEHUB_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {FinalizeL1DepositParams} from "../bridge/interfaces/IL1Nullifier.sol";
import {L2Message, TxStatus} from "../common/Messaging.sol";
import {L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";
import {WrongL2Sender, WrongMsgLength} from "../bridge/L1BridgeContractErrors.sol";
import {AddressAlreadySet, DepositDoesNotExist, DepositExists, InvalidProof, InvalidSelector, L2WithdrawalMessageWrongLength, LegacyBridgeNotSet, LegacyMethodForNonL1Token, SharedBridgeKey, SharedBridgeValueNotSet, TokenNotLegacy, Unauthorized, WithdrawalAlreadyFinalized, ZeroAddress} from "../common/L1ContractErrors.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IMailboxImpl} from "../state-transition/chain-interfaces/IMailboxImpl.sol";
import {IL1ERC20Bridge} from "../bridge/interfaces/IL1ERC20Bridge.sol";
import {IAssetRouterBase, LEGACY_ENCODING_VERSION, NEW_ENCODING_VERSION} from "../bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "../bridge/asset-router/AssetRouterBase.sol";
import {IL1NativeTokenVault} from "../bridge/ntv/IL1NativeTokenVault.sol";

import {L1ShadowAccount} from "./L1ShadowAccount.sol";
import {Create2Address} from "./Create2Address.sol";
import {ShadowAccountOp} from "./L2InteropCenter.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The L1InteropHandler contract is responsible for handling interops from L2.
contract L1InteropHandler {

    address public l2InteropCenterAddress;

    IL1NativeTokenVault public  l1NativeTokenVault;

    IBridgehubBase public  BRIDGE_HUB;

    constructor(address _bridgehubAddress) {
        BRIDGE_HUB = IBridgehubBase(_bridgehubAddress);
    }

    function receiveInteropFromL2(
        // FinalizeL1DepositParams memory _tokenWithdrawalParams,
        FinalizeL1DepositParams memory _bundleWithdrawalParams
    ) external {
        _verifyWithdrawal(_bundleWithdrawalParams, false, false);

        // The _bundleWithdrawalParams.message is expected to be an abi-encoded array of ShadowAccountOp structs.
        // Decode the bytes contained in _bundleWithdrawalParams.message to retrieve the calls for the shadow account.
        (address l2Sender, ShadowAccountOp[] memory ops) = abi.decode(_bundleWithdrawalParams.message, (address, ShadowAccountOp[]));

        // deploy shadow account if needed
        address shadowAccount = deployShadowAccount(l2Sender);

        // execute bundle withdrawal
        _executeBundleWithdrawal(shadowAccount, ops);
    }

    function deployShadowAccount(
        address _l2CallerAddress
    ) public returns (address) {
        bytes32 salt = keccak256(abi.encode(_l2CallerAddress));
        bytes32 bytecodeHash = keccak256(type(L1ShadowAccount).creationCode);
        address shadowAccountAddress = Create2Address.getNewAddressCreate2EVM(address(this), salt, bytecodeHash);
        if (shadowAccountAddress.code.length == 0) {
            L1ShadowAccount shadowAccount = new L1ShadowAccount{salt: salt}();
            require(shadowAccountAddress == address(shadowAccount), "L1InteropHandler: shadow account deployment failed");
        }
        return shadowAccountAddress;
    }

    function _executeBundleWithdrawal(
        address _shadowAccount,
        ShadowAccountOp[] memory ops
    ) internal {
        for (uint256 i = 0; i < ops.length; i++) {
            L1ShadowAccount(payable(_shadowAccount)).executeFromIH(ops[i].target, ops[i].value, ops[i].data);
        }
    }

    function _isBaseTokenWithdrawal(
        bytes32 _assetId,
        uint256 _chainId
    ) internal view returns (bool) {
        return _assetId == BRIDGE_HUB.baseTokenAssetId(_chainId);
    }

    error WrongL2Sender(address l2Sender);
    error InvalidProof();

    /// @notice Verifies the validity of a withdrawal message from L2 and returns withdrawal details.
    /// @param _finalizeWithdrawalParams The structure that holds all necessary data to finalize withdrawal
    function _verifyWithdrawal(
        FinalizeL1DepositParams memory _finalizeWithdrawalParams,
        bool _baseTokenWithdrawal,
        bool overrideL2Sender
    ) internal view {
        L2Message memory l2ToL1Message;
        {
            address l2Sender = _finalizeWithdrawalParams.l2Sender;

            bool isL2SenderCorrect = l2Sender == L2_ASSET_ROUTER_ADDR ||
                l2Sender == L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR;
            if (!isL2SenderCorrect && overrideL2Sender) {
                revert WrongL2Sender(l2Sender);
            }

            l2ToL1Message = L2Message({
                txNumberInBatch: _finalizeWithdrawalParams.l2TxNumberInBatch,
                sender: _baseTokenWithdrawal ? L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR : l2Sender,
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

    error LegacyBridgeMessageNotSupported();

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

            revert LegacyBridgeMessageNotSupported();
        } else if (bytes4(functionSignature) == AssetRouterBase.finalizeDeposit.selector) {
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