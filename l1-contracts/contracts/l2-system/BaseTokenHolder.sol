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
    BaseTokenTotalSupplyBackfillNotNeeded,
    L1ChainIdNotSet,
    Unauthorized
} from "../common/L1ContractErrors.sol";

/**
 * @title BaseTokenHolder
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Contract that holds the base token reserves for the chain.
 * @dev This contract replaces the mint/burn approach with a transfer-based approach for better EVM compatibility.
 *
 * ## Design Rationale
 *
 * Instead of minting base tokens during deposits and interops, tokens are transferred from this holder contract.
 * This makes the system more compatible with standard EVM tooling like Foundry.
 *
 * ## Initial Balance
 *
 * During migration, this contract is initialized with 2^127 - 1 base tokens.
 * On Era, the existing total supply is tracked separately in L2BaseTokenEra.__DEPRECATED_totalSupply.
 * On ZK OS, the full amount is minted since balances are tracked natively.
 * This is sufficient for any reasonable base token, as no token has a total supply greater than 2^127.
 *
 * ## Overflow/Underflow Prevention
 *
 * - Overflow: Before any user receives base tokens, this contract loses the same amount.
 *   Thus, no balance can overflow.
 * - Underflow: The chain operator must ensure the base token's total supply is below 2^127.
 *   This is true for most popular tokens including meme coins.
 *
 * ## ETH Transfer Events
 *
 * On Era, Transfer events are automatically emitted during any ETH transfer since all transfers
 * go via MsgValueSimulator which calls transferFromTo. On ZK OS, standard ETH transfers work natively.
 * This allows a single implementation to work correctly on both chain types.
 *
 * ## Force-received funds caveat
 *
 * The implicit meaning of this contract's balance is "funds that the chain can still mint".
 * On Era, totalSupply is computed as __DEPRECATED_totalSupply + INITIAL_BASE_TOKEN_HOLDER_BALANCE - eraAccountBalance[BaseTokenHolder].
 * On ZK OS, totalSupply is computed as zkosPreV31TotalSupply + (INITIAL - holder.balance).
 * If funds are force-sent to this contract (bypassing access controls), the holder balance
 * would increase, causing totalSupply() to undercount. This can happen via:
 * - Being the refund recipient of an L1->L2 transaction (both Era and ZK OS).
 * - Receiving funds via selfdestruct (ZK OS only; Era does not support selfdestruct).
 * However, this is a view-only issue — no funds are at risk, as the accounting for bridging and
 * withdrawals does not rely on totalSupply().
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

    /// @notice Modifier that restricts access to the InteropHandler only.
    modifier onlyInteropHandler() {
        if (msg.sender != L2_INTEROP_HANDLER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Modifier that restricts access to callers that can bridge base tokens.
    /// @dev InteropCenter: returns burned tokens during interop operations
    /// @dev NativeTokenVault: returns tokens during bridged base token burns
    /// @dev L2BaseToken: returns burned tokens during withdrawals
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

    /// @notice Gives out base tokens from the holder to a recipient.
    /// @dev This replaces the mint operation. Tokens are transferred from this contract's balance.
    /// @dev NOTE: This is not the only way funds leave this contract:
    /// @dev - On both Era and ZK OS, balance is also manipulated directly via storage by the VM.
    /// @dev WARNING: Since standard ETH transfer is used, the transfer may fail if the recipient
    /// @dev rejects ETH. Only trusted recipients should be used to guarantee successful operation.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    /// @param _fromChainId The source chain ID of the bridging operation.
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

    /// @notice Receives base tokens and initiates bridging.
    /// @dev Called by InteropCenter, NativeTokenVault, and L2BaseToken during bridging operations.
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

    /// @dev Returns the configured L1 chain id and rejects non-zero flows before initialization.
    function _l1ChainIdChecked() internal view returns (uint256 l1ChainId) {
        l1ChainId = L2_NATIVE_TOKEN_VAULT.L1_CHAIN_ID();
        if (l1ChainId == 0) {
            revert L1ChainIdNotSet();
        }
    }

    /// @notice Fallback to accept base token transfers from L2BaseToken only.
    /// @dev Only accepts transfers from L2BaseToken during initL2.
    /// @dev For bridging operations, use burnAndStartBridging() instead.
    receive() external payable onlyL2BaseToken {}
}
