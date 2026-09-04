// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts-v4/utils/Address.sol";

import {IL2BaseToken} from "../interfaces/IL2BaseToken.sol";
import {
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    MINT_BASE_TOKEN_HOOK
} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "../../common/Config.sol";
import {
    BaseTokenHolderAlreadyInitialized,
    BaseTokenHolderMintFailed,
    Unauthorized
} from "../../common/L1ContractErrors.sol";

/**
 * @title L2BaseToken
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice L2 Base Token contract for ZK OS chains.
 * @dev On ZK OS chains, the native ETH is used directly, so balance management is handled natively.
 * @dev Base-token withdrawals use the InteropCenter and L2 AssetRouter; this contract tracks total supply.
 *
 * ## Initialization (Genesis/Upgrade)
 *
 * During genesis or V31 upgrade, `initL2()` must be called to:
 * 1. Set the L1 chain ID
 * 2. Mint 2^127 - 1 tokens to this contract via the MINT_BASE_TOKEN_HOOK
 * 3. Transfer all tokens to BaseTokenHolder to establish the balance invariant
 *
 * This function must be called via the ComplexUpgrader contract using delegatecall.
 * The ComplexUpgrader (at L2_COMPLEX_UPGRADER_ADDR) is the only authorized caller.
 *
 * This is done in `L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit()`.
 */
contract L2BaseToken is IL2BaseToken {
    /// @notice Ensures that only the ComplexUpgrader can call the function.
    modifier onlyComplexUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Deprecated slot, retained to preserve the storage layout. Formerly `eraAccountBalance`,
    /// the EraVM base-token balance ledger; current balances live in native account state.
    // slither-disable-next-line uninitialized-state
    mapping(address account => uint256 balance) internal __DEPRECATED_eraAccountBalance;

    /// @dev Deprecated pre-V31 total-supply slot. Current supply is derived from BaseTokenHolder.
    // slither-disable-next-line uninitialized-state
    uint256 internal __DEPRECATED_totalSupply;

    /// @notice Whether initL2 has already been called.
    bool internal baseTokenHolderBalanceInitialized;

    /// @notice The chain ID of L1.
    uint256 public L1_CHAIN_ID;

    /// @dev Retained in place so existing storage remains unchanged.
    uint256[46] private __gap;

    /// @notice The pre-V31 total supply for ZKOS chains.
    /// @dev ZKsync OS chains did not track total supply on-chain before v31. Existing chains had
    /// this slot backfilled by the v31 service transaction, and the v32 upgrade is forbidden
    /// on L1 until that happened (see `V32UpgradeZKsyncOS`), so the value here is
    /// always final. Fresh chains have no pre-v31 history and keep zero.
    // slither-disable-next-line uninitialized-state
    uint256 public override zkosPreV31TotalSupply;

    /// @notice Returns the total circulating supply of base tokens.
    /// @dev Computed as: zkosPreV31TotalSupply + (INITIAL_BASE_TOKEN_HOLDER_BALANCE - BaseTokenHolder.balance)
    /// @dev The delta (INITIAL - holder.balance) tracks tokens minted after V31 via the BaseTokenHolder pattern.
    /// @dev The subtraction cannot underflow, by construction: before the v31 upgrade the holder's
    /// balance was zero and all other balances summed to `zkosPreV31TotalSupply`; the upgrade then
    /// minted exactly `INITIAL_BASE_TOKEN_HOLDER_BALANCE` to the holder, and every flow since —
    /// force-sent value included — only moves balance between the holder and other accounts. The
    /// sum of ALL balances (the holder's included) therefore never exceeds
    /// `zkosPreV31TotalSupply + INITIAL_BASE_TOKEN_HOLDER_BALANCE`, so neither does the holder's
    /// balance alone.
    function totalSupply() external view override returns (uint256) {
        return zkosPreV31TotalSupply + INITIAL_BASE_TOKEN_HOLDER_BALANCE - L2_BASE_TOKEN_HOLDER_ADDR.balance;
    }

    /// @notice Initializes the L2 Base Token contract during genesis or V31 upgrade.
    /// @dev Sets the L1 chain ID, mints 2^127 - 1 tokens to this contract via the mint hook,
    /// then transfers all tokens to BaseTokenHolder.
    /// @dev Can only be called by the ComplexUpgrader contract.
    /// @param _l1ChainId The chain ID of L1.
    function initL2(uint256 _l1ChainId) external override onlyComplexUpgrader {
        if (baseTokenHolderBalanceInitialized) {
            revert BaseTokenHolderAlreadyInitialized();
        }
        baseTokenHolderBalanceInitialized = true;
        L1_CHAIN_ID = _l1ChainId;

        // Mint INITIAL_BASE_TOKEN_HOLDER_BALANCE tokens to this contract via the mint hook
        (bool mintSuccess, ) = MINT_BASE_TOKEN_HOOK.call(abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE));
        if (!mintSuccess) {
            revert BaseTokenHolderMintFailed();
        }

        // Transfer all minted tokens to BaseTokenHolder
        Address.sendValue(payable(L2_BASE_TOKEN_HOLDER_ADDR), INITIAL_BASE_TOKEN_HOLDER_BALANCE);
    }
}
