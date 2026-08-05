// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts-v4/utils/Address.sol";

import {IBaseTokenHolder} from "./interfaces/IBaseTokenHolder.sol";
import {
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {BaseTokenNativeToThisChain, RecoverToL1NotSupported, Unauthorized} from "../common/L1ContractErrors.sol";

/**
 * @title BaseTokenHolder
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Holds the chain's base-token reserve: transfers from this holder replace minting and value
 * received here replaces burning, for better EVM-tooling compatibility.
 * See {protocol-docs/bridging.md#base-token-handling}.
 * @dev Initialized with 2^127 - 1 tokens. No balance can overflow (users only gain what the holder
 * loses); the operator must keep the base token's total supply below 2^127 to avoid underflow.
 * @dev The base token is escrowed here, so its contract-level bridge flows converge in this
 * contract; each one is reported to `L2NativeTokenVault`, which keeps the interop bookkeeping for
 * every asset (the base token included) in one place. Flows performed by the VM directly (see the
 * note on `give`) bypass this reporting.
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
    /// @dev L2BaseToken: burns the withdrawn value during legacy `withdraw`/`withdrawWithMessage`
    modifier onlyBridgingCaller() {
        if (
            msg.sender != L2_INTEROP_CENTER_ADDR &&
            msg.sender != L2_NATIVE_TOKEN_VAULT_ADDR &&
            msg.sender != L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR
        ) {
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

        // Record before transferring so the recipient cannot interleave another operation from its
        // receive hook before this operation is accounted for.
        L2_NATIVE_TOKEN_VAULT.recordBaseTokenBridgingFromChain(_fromChainId, _amount);
        Address.sendValue(payable(_to), _amount);
        emit BaseTokenMintedInterop(_to, _amount);
    }

    /// @inheritdoc IBaseTokenHolder
    function recoverBaseToken(address _to, uint256 _amount, uint256 _toChainId) external override onlyNativeTokenVault {
        if (_amount == 0) {
            return;
        }

        _assertBaseTokenRecoveryIsAccountingNeutral(_toChainId);
        Address.sendValue(payable(_to), _amount);
        emit BaseTokenRecovered(_to, _amount);
    }

    /// @notice Receives base tokens and records the outbound bridge flow.
    /// @dev Called by InteropCenter, NativeTokenVault, and L2BaseToken (its `withdraw` path) during bridging operations.
    /// @param _toChainId The chain ID which the funds are sent to.
    function burnAndStartBridging(uint256 _toChainId) external payable onlyBridgingCaller {
        if (msg.value != 0) {
            L2_NATIVE_TOKEN_VAULT.recordBaseTokenBridgingToChain(_toChainId, msg.value);
        }
        emit BaseTokenBurntInterop(msg.sender, _toChainId, msg.value);
    }

    /// @inheritdoc IBaseTokenHolder
    function recordBaseTokenDeposit(uint256 _fromChainId, uint256 _amount) external onlyL2BaseToken {
        if (_amount == 0) {
            return;
        }

        L2_NATIVE_TOKEN_VAULT.recordBaseTokenBridgingFromChain(_fromChainId, _amount);
    }

    /// @dev Asserts that returning a failed bridge-out's escrow needs no bookkeeping reversal:
    /// `totalWithdrawalsToL1` is append-only because L2 -> L1 withdrawals are never revertable, and the
    /// base token never originates from this chain, so `L2NativeTokenVault.bridgedOut` holds nothing to
    /// re-credit for it.
    /// @dev `L1_CHAIN_ID` needs no zero-check: the vault is initialized during genesis or the upgrade,
    /// before any bridge-out (and hence any recovery) can exist.
    function _assertBaseTokenRecoveryIsAccountingNeutral(uint256 _toChainId) internal view {
        require(_toChainId != L2_NATIVE_TOKEN_VAULT.L1_CHAIN_ID(), RecoverToL1NotSupported());
        require(
            L2_NATIVE_TOKEN_VAULT.originChainId(L2_NATIVE_TOKEN_VAULT.BASE_TOKEN_ASSET_ID()) != block.chainid,
            BaseTokenNativeToThisChain()
        );
    }

    /// @notice Accepts the initial balance transfer from L2BaseToken during `initL2`.
    /// @dev Bridging operations must use `burnAndStartBridging` instead.
    receive() external payable onlyL2BaseToken {}
}
