// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts-v4/utils/Address.sol";

import {IBaseTokenHolder} from "./interfaces/IBaseTokenHolder.sol";
import {
    L2_ASSET_TRACKER,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {Unauthorized} from "../common/L1ContractErrors.sol";

/**
 * @title BaseTokenHolder
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Holds the chain's base-token reserve: transfers from this holder replace minting and value
 * received here replaces burning, for better EVM-tooling compatibility.
 * See {protocol-docs/bridging.md#base-token-handling}.
 * @dev Initialized with 2^127 - 1 tokens. No balance can overflow (users only gain what the holder
 * loses); the operator must keep the base token's total supply below 2^127 to avoid underflow.
 */
// slither-disable-next-line locked-ether
contract BaseTokenHolder is IBaseTokenHolder {
    /// @notice Modifier that restricts access to the L2InteropHandler only.
    modifier onlyInteropHandler() {
        if (msg.sender != L2_INTEROP_HANDLER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Modifier that restricts access to callers that can bridge base tokens.
    /// @dev InteropCenter: burns base-token value when sending an interop bundle
    /// @dev NativeTokenVault: burns base-token value during bridged base-token burns
    modifier onlyBridgingCaller() {
        if (msg.sender != L2_INTEROP_CENTER_ADDR && msg.sender != L2_NATIVE_TOKEN_VAULT_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Modifier that restricts access to the NativeTokenVault only (failed-transfer recovery).
    modifier onlyNativeTokenVault() {
        if (msg.sender != L2_NATIVE_TOKEN_VAULT_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Modifier that restricts access to L2BaseToken only.
    /// @dev Used for receiving initial balance during initL2.
    modifier onlyL2BaseToken() {
        if (msg.sender != L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @inheritdoc IBaseTokenHolder
    /// @dev This is not the only way funds leave this contract: the VM may also move its balance
    /// directly via storage.
    function give(address _to, uint256 _amount, uint256 _fromChainId) external override onlyInteropHandler {
        if (_amount == 0) {
            return;
        }

        // Notify the asset tracker BEFORE transferring, so that
        // _needToForceSetAssetMigrationOnL2 can use totalSupply() == 0 consistently.
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(_fromChainId, _amount);
        Address.sendValue(payable(_to), _amount);
        emit BaseTokenMintedInterop(_to, _amount);
    }

    /// @inheritdoc IBaseTokenHolder
    function recoverBaseToken(address _to, uint256 _amount, uint256 _toChainId) external override onlyNativeTokenVault {
        if (_amount == 0) {
            return;
        }

        L2_ASSET_TRACKER.assertBaseTokenRecoveryIsAccountingNeutral(_toChainId);
        Address.sendValue(payable(_to), _amount);
        emit BaseTokenRecovered(_to, _amount);
    }

    /// @notice Receives base tokens and initiates bridging by notifying L2AssetTracker.
    /// @dev Called by InteropCenter and NativeTokenVault during bridging operations.
    /// @dev This function notifies L2AssetTracker to track the bridging operation.
    /// @param _toChainId The chain ID which the funds are sent to.
    function burnAndStartBridging(uint256 _toChainId) external payable onlyBridgingCaller {
        L2_ASSET_TRACKER.handleInitiateBaseTokenBridgingOnL2(_toChainId, msg.value);
        emit BaseTokenBurntInterop(msg.sender, _toChainId, msg.value);
    }

    /// @notice Accepts the initial balance transfer from L2BaseToken during `initL2`.
    /// @dev Bridging operations must use `burnAndStartBridging` instead.
    receive() external payable onlyL2BaseToken {}
}
