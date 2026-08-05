// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts-v4/utils/Address.sol";

import {IBaseTokenHolder} from "./interfaces/IBaseTokenHolder.sol";
import {InteropL2Info, SavedTotalSupply} from "../common/L2AssetBookkeeping.sol";
import {
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT
} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {
    BaseTokenBookkeepingAlreadyInitialized,
    BaseTokenBookkeepingNotInitialized,
    BaseTokenNativeToThisChain,
    BaseTokenTotalSupplyBackfillNotNeeded,
    L1ChainIdNotSet,
    RecoverToL1NotSupported,
    Unauthorized
} from "../common/L1ContractErrors.sol";

/**
 * @title BaseTokenHolder
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Holds the chain's base-token reserve: transfers from this holder replace minting and value
 * received here replaces burning, for better EVM-tooling compatibility.
 * See {protocol-docs/bridging.md#base-token-handling}.
 * @dev Initialized with 2^127 - 1 tokens. No balance can overflow (users only gain what the holder
 * loses); the operator must keep the base token's total supply below 2^127 to avoid underflow.
 * @dev On Era every ETH transfer routes through MsgValueSimulator (which emits Transfer events), so the
 * same implementation behaves consistently on Era and ZK OS.
 */
// slither-disable-next-line locked-ether
contract BaseTokenHolder is IBaseTokenHolder {
    /// @notice L2-side accounting of base-token L1 <-> L2 flows while this chain settles on L1.
    /// @dev This write-only bookkeeping is the base-token counterpart of
    /// `L2NativeTokenVault.interopInfo`. The base token is escrowed here, so all of its outbound
    /// flows converge in this contract; Era bootloader deposits are recorded through
    /// `recordBaseTokenDeposit`.
    InteropL2Info public override baseTokenInteropInfo;

    /// @notice Supply captured before BaseTokenHolder began recording bridge flows.
    /// @dev Existing Era chains initialize this from their pre-upgrade supply. Existing ZKsync OS
    /// chains start with a provisional zero and replace it when their pre-v31 supply is backfilled.
    /// Fresh chains initialize it to zero.
    SavedTotalSupply public override baseTokenPreTrackingTotalSupply;

    /// @notice Whether the bookkeeping snapshot has been initialized.
    bool public bookkeepingInitialized;

    /// @notice Whether the provisional ZKsync OS snapshot still needs its governance backfill.
    bool public override baseTokenPreTrackingTotalSupplyBackfillPending;

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

    /// @notice Modifier that restricts access to ComplexUpgrader only.
    modifier onlyComplexUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
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
        _recordFinalizeBaseTokenBridging(_fromChainId, _amount);
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
            uint256 l1ChainId = _l1ChainIdChecked();
            if (
                _toChainId == l1ChainId &&
                L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == l1ChainId
            ) {
                baseTokenInteropInfo.totalWithdrawalsToL1 += msg.value;
            }
        }
        emit BaseTokenBurntInterop(msg.sender, _toChainId, msg.value);
    }

    /// @inheritdoc IBaseTokenHolder
    function recordBaseTokenDeposit(uint256 _fromChainId, uint256 _amount) external onlyL2BaseToken {
        _recordFinalizeBaseTokenBridging(_fromChainId, _amount);
    }

    /// @inheritdoc IBaseTokenHolder
    function initializeBookkeeping(
        SavedTotalSupply calldata _preTrackingTotalSupply,
        bool _needsBackfill
    ) external onlyComplexUpgrader {
        if (bookkeepingInitialized) {
            revert BaseTokenBookkeepingAlreadyInitialized();
        }
        if (!_preTrackingTotalSupply.isSaved) {
            revert BaseTokenBookkeepingNotInitialized();
        }

        bookkeepingInitialized = true;
        baseTokenPreTrackingTotalSupplyBackfillPending = _needsBackfill;
        baseTokenPreTrackingTotalSupply = _preTrackingTotalSupply;
    }

    /// @inheritdoc IBaseTokenHolder
    function backfillBaseTokenPreTrackingTotalSupply(uint256 _amount) external onlyL2BaseToken {
        if (!bookkeepingInitialized || !baseTokenPreTrackingTotalSupply.isSaved) {
            revert BaseTokenBookkeepingNotInitialized();
        }
        if (!baseTokenPreTrackingTotalSupplyBackfillPending) {
            revert BaseTokenTotalSupplyBackfillNotNeeded();
        }

        baseTokenPreTrackingTotalSupply.amount = _amount;
        baseTokenPreTrackingTotalSupplyBackfillPending = false;
    }

    /// @dev Records an inbound base-token flow attributable to L1 while L1 is the settlement layer.
    function _recordFinalizeBaseTokenBridging(uint256 _fromChainId, uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        uint256 l1ChainId = _l1ChainIdChecked();
        if (
            _fromChainId == l1ChainId && L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId() == l1ChainId
        ) {
            baseTokenInteropInfo.totalSuccessfulDepositsFromL1 += _amount;
        }
    }

    /// @dev Asserts that returning a failed bridge-out's escrow needs no bookkeeping reversal:
    /// `totalWithdrawalsToL1` is append-only because L2 -> L1 withdrawals are never revertable, and the
    /// base token never originates from this chain, so `L2NativeTokenVault.bridgedOut` holds nothing to
    /// re-credit for it.
    function _assertBaseTokenRecoveryIsAccountingNeutral(uint256 _toChainId) internal view {
        require(_toChainId != _l1ChainIdChecked(), RecoverToL1NotSupported());
        require(
            L2_NATIVE_TOKEN_VAULT.originChainId(L2_NATIVE_TOKEN_VAULT.BASE_TOKEN_ASSET_ID()) != block.chainid,
            BaseTokenNativeToThisChain()
        );
    }

    /// @dev Returns the configured L1 chain id and rejects non-zero flows before initialization.
    function _l1ChainIdChecked() internal view returns (uint256 l1ChainId) {
        l1ChainId = L2_NATIVE_TOKEN_VAULT.L1_CHAIN_ID();
        if (l1ChainId == 0) {
            revert L1ChainIdNotSet();
        }
    }

    /// @notice Accepts the initial balance transfer from L2BaseToken during `initL2`.
    /// @dev Bridging operations must use `burnAndStartBridging` instead.
    receive() external payable onlyL2BaseToken {}
}
