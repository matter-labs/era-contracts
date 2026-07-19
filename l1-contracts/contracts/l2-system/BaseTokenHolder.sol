// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts-v4/utils/Address.sol";

import {IBaseTokenHolder} from "./interfaces/IBaseTokenHolder.sol";
import {InteropL2Info} from "../bridge/ntv/IL2NativeTokenVault.sol";
import {
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {
    BaseTokenNativeToThisChain,
    L1ChainIdNotSet,
    RecoverToL1NotSupported,
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
 * On ZK OS, totalSupply is computed as INITIAL - holder.balance.
 * If funds are force-sent to this contract (bypassing access controls), the holder balance
 * would increase, causing totalSupply() to undercount. This can happen via:
 * - Being the refund recipient of an L1->L2 transaction (both Era and ZK OS).
 * - Receiving funds via selfdestruct (ZK OS only; Era does not support selfdestruct).
 * However, this is a view-only issue — no funds are at risk, as the accounting for bridging and
 * withdrawals does not rely on totalSupply().
 */
// slither-disable-next-line locked-ether
contract BaseTokenHolder is IBaseTokenHolder {
    /// @notice L2-side accounting of base-token L1 <-> L2 flows. All chains are assumed to settle on
    /// L1, so no settlement-layer distinction is made.
    /// @dev This is write-only bookkeeping kept for future use; it is not consulted by any bridging
    /// decision. It is the base-token counterpart of `L2NativeTokenVault.interopInfo` (the base token
    /// is escrowed here rather than in the vault, so all its flows converge in this contract).
    /// @dev For the base token, failed deposits are refunded on L2 to the refundRecipient rather than
    /// later claimed on L1, so the gap between initiated deposits and `totalSuccessfulDepositsFromL1`
    /// should not be interpreted as uniformly "claimable on L1" across all asset types.
    InteropL2Info public override baseTokenInteropInfo;

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

        // Record BEFORE transferring, so the bookkeeping cannot be manipulated via the
        // recipient's receive hook.
        _recordFinalizeBaseTokenBridging(_fromChainId, _amount);
        Address.sendValue(payable(_to), _amount);
        emit BaseTokenMintedInterop(_to, _amount);
    }

    /// @notice Returns base tokens escrowed by a failed/timed-out bridge-out to the original depositor.
    /// @dev The inverse of `burnAndStartBridging`: asserts the bridge-out is recoverable (L2->L2 only;
    /// L2->L1 withdrawals are never revertable) — then returns the value.
    /// Callable only by the NativeTokenVault (atomic-interop timeout recovery). Like `give`, this
    /// pushes ETH and may revert if `_to` rejects it — recovery targets the original depositor by design.
    /// @dev Only L2->L2 bridge-outs are recoverable, and their forward accounting records nothing to
    /// reverse: the base token is never native to this chain (so no `bridgedOut` amount was recorded at
    /// initiate) and the destination is not L1 (so no `totalWithdrawalsToL1` bump). Both invariants are
    /// asserted below.
    /// @param _to The original depositor to refund.
    /// @param _amount The amount of base tokens to return.
    /// @param _toChainId The original bridge-out destination chain id (to reverse the matching accounting).
    function recoverBaseToken(address _to, uint256 _amount, uint256 _toChainId) external override onlyNativeTokenVault {
        if (_amount == 0) {
            return;
        }

        // L2->L1 interop is never revertable ({InteropCenter} rejects L1-destined atomic bundles at
        // send): `totalWithdrawalsToL1` must stay append-only.
        require(_toChainId != _l1ChainId(), RecoverToL1NotSupported());
        // The base token can never originate from this chain (`_recordFinalizeBaseTokenBridging`
        // relies on the same invariant), so there is no bridged-out amount to re-credit.
        require(
            L2_NATIVE_TOKEN_VAULT.originChainId(L2_NATIVE_TOKEN_VAULT.BASE_TOKEN_ASSET_ID()) != block.chainid,
            BaseTokenNativeToThisChain()
        );
        Address.sendValue(payable(_to), _amount);
        emit BaseTokenRecovered(_to, _amount);
    }

    /// @notice Receives base tokens and initiates bridging, recording the outbound flow.
    /// @dev Called by InteropCenter and NativeTokenVault during bridging operations.
    /// @param _toChainId The chain ID which the funds are sent to.
    function burnAndStartBridging(uint256 _toChainId) external payable onlyBridgingCaller {
        // All chains are assumed to settle on L1, so every L1-destined withdrawal is recorded.
        if (msg.value != 0 && _toChainId == _l1ChainIdChecked()) {
            baseTokenInteropInfo.totalWithdrawalsToL1 += msg.value;
        }
        emit BaseTokenBurntInterop(msg.sender, _toChainId, msg.value);
    }

    /// @notice Records an inbound base-token bridging operation that is finalized outside this
    /// contract: the Era bootloader mints L1->L2 deposits directly via `L2BaseTokenEra.mint`.
    /// @dev Called by L2BaseToken before any balance changes are performed.
    /// @param _fromChainId The source chain ID of the bridging operation.
    /// @param _amount The amount of base tokens being bridged in.
    function recordBaseTokenDeposit(uint256 _fromChainId, uint256 _amount) external override onlyL2BaseToken {
        _recordFinalizeBaseTokenBridging(_fromChainId, _amount);
    }

    /// @notice Records an inbound base-token flow in `baseTokenInteropInfo`.
    /// @dev All chains are assumed to settle on L1, so every L1-originated deposit is recorded.
    function _recordFinalizeBaseTokenBridging(uint256 _fromChainId, uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }
        if (_fromChainId == _l1ChainIdChecked()) {
            baseTokenInteropInfo.totalSuccessfulDepositsFromL1 += _amount;
        }
    }

    /// @dev Returns the L1 chain id, reverting if it is not set yet (i.e. before the genesis upgrade,
    /// where no value is transferred, so the recording paths should not be reachable with a non-zero
    /// amount).
    function _l1ChainIdChecked() internal view returns (uint256 l1ChainId) {
        l1ChainId = _l1ChainId();
        require(l1ChainId != 0, L1ChainIdNotSet());
    }

    /// @dev The L1 chain id as initialized on the NativeTokenVault during genesis/upgrade.
    function _l1ChainId() internal view returns (uint256) {
        return L2_NATIVE_TOKEN_VAULT.L1_CHAIN_ID();
    }

    /// @notice Fallback to accept base token transfers from L2BaseToken only.
    /// @dev Only accepts transfers from L2BaseToken during initL2.
    /// @dev For bridging operations, use burnAndStartBridging() instead.
    receive() external payable onlyL2BaseToken {}
}
