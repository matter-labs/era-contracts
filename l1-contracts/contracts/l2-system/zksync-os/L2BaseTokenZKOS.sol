// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts-v4/utils/Address.sol";

import {L2BaseTokenBase} from "../L2BaseTokenBase.sol";
import {IL2BaseTokenZKOS} from "./interfaces/IL2BaseTokenZKOS.sol";
import {L2_BASE_TOKEN_HOLDER_ADDR, MINT_BASE_TOKEN_HOOK} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "../../common/Config.sol";
import {BaseTokenHolderAlreadyInitialized, BaseTokenHolderMintFailed} from "../../common/L1ContractErrors.sol";

/**
 * @title L2BaseTokenZKOS
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice L2 Base Token contract for ZK OS chains.
 * @dev On ZK OS chains, the native ETH is used directly, so balance management is handled natively.
 * @dev This contract provides the withdrawal interface to bridge ETH back to L1 and totalSupply tracking.
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
contract L2BaseTokenZKOS is L2BaseTokenBase, IL2BaseTokenZKOS {
    /// @notice The pre-V31 total supply for ZKOS chains.
    /// @dev ZKsync OS chains did not track total supply on-chain before v31. Existing chains had
    /// this slot backfilled by the draft-v31 service transaction, and the v31 upgrade is forbidden
    /// on L1 until that happened (see `DefaultUpgradeZKsyncOS`), so the value here is
    /// always final. Fresh chains have no pre-v31 history and keep zero.
    // slither-disable-next-line uninitialized-state
    uint256 public override zkosPreV31TotalSupply;

    /// @notice Returns the total circulating supply of base tokens.
    /// @dev Computed as: zkosPreV31TotalSupply + (INITIAL_BASE_TOKEN_HOLDER_BALANCE - BaseTokenHolder.balance)
    /// @dev The delta (INITIAL - holder.balance) tracks tokens minted after V31 via the BaseTokenHolder pattern.
    function totalSupply() external view returns (uint256) {
        return zkosPreV31TotalSupply + INITIAL_BASE_TOKEN_HOLDER_BALANCE - L2_BASE_TOKEN_HOLDER_ADDR.balance;
    }

    /// @notice Initializes the L2 Base Token contract during genesis or V31 upgrade.
    /// @dev Sets the L1 chain ID, mints 2^127 - 1 tokens to this contract via the mint hook,
    /// then transfers all tokens to BaseTokenHolder.
    /// @dev Can only be called by the ComplexUpgrader contract.
    /// @param _l1ChainId The chain ID of L1.
    function initL2(uint256 _l1ChainId) external onlyComplexUpgrader {
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
