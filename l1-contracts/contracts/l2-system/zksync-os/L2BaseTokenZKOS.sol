// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts-v4/utils/Address.sol";

import {L2BaseTokenBase} from "../L2BaseTokenBase.sol";
import {IL2BaseTokenZKOS} from "./interfaces/IL2BaseTokenZKOS.sol";
import {L2_BASE_TOKEN_HOLDER_ADDR, L2_COMPLEX_UPGRADER_ADDR, MINT_BASE_TOKEN_HOOK} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "../../common/Config.sol";
import {BaseTokenHolderMintFailed, Unauthorized} from "../../common/L1ContractErrors.sol";

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
 * During genesis or V31 upgrade, `initializeBaseTokenHolderBalance()` must be called to:
 * 1. Mint 2^127 - 1 tokens to this contract via the MINT_BASE_TOKEN_HOOK
 * 2. Transfer all tokens to BaseTokenHolder to establish the balance invariant
 *
 * This function must be called via the ComplexUpgrader contract using delegatecall.
 * The ComplexUpgrader (at L2_COMPLEX_UPGRADER_ADDR) is the only authorized caller.
 *
 * This is done in `L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit()`.
 */
contract L2BaseTokenZKOS is L2BaseTokenBase, IL2BaseTokenZKOS {
    /// @notice Returns the total circulating supply of base tokens.
    /// @dev Computed as: _zkosPreV31TotalSupply + (INITIAL_BASE_TOKEN_HOLDER_BALANCE - BaseTokenHolder.balance)
    /// @dev _zkosPreV31TotalSupply captures the total supply that existed before the V31 upgrade.
    /// @dev The delta (INITIAL - holder.balance) tracks tokens minted after V31 via the BaseTokenHolder pattern.
    function totalSupply() external view returns (uint256) {
        return _zkosPreV31TotalSupply + (INITIAL_BASE_TOKEN_HOLDER_BALANCE - L2_BASE_TOKEN_HOLDER_ADDR.balance);
    }

    /// @notice Sets the pre-V31 total supply for ZKOS chains during V31 upgrade.
    /// @dev Can only be called by the ComplexUpgrader contract.
    /// @param _totalSupply The total supply that existed before the V31 upgrade.
    function setZkosPreV31TotalSupply(uint256 _totalSupply) external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _zkosPreV31TotalSupply = _totalSupply;
    }

    /// @notice Initializes the BaseTokenHolder's balance during genesis or V31 upgrade.
    /// @dev This function mints 2^127 - 1 tokens to this contract via the mint hook,
    /// @dev then transfers all tokens to BaseTokenHolder.
    /// @dev Can only be called by the ComplexUpgrader contract.
    function initializeBaseTokenHolderBalance() external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }

        // Mint INITIAL_BASE_TOKEN_HOLDER_BALANCE tokens to this contract via the mint hook
        (bool mintSuccess, ) = MINT_BASE_TOKEN_HOOK.call(abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE));
        if (!mintSuccess) {
            revert BaseTokenHolderMintFailed();
        }

        // Transfer all minted tokens to BaseTokenHolder
        Address.sendValue(payable(L2_BASE_TOKEN_HOLDER_ADDR), INITIAL_BASE_TOKEN_HOLDER_BALANCE);
    }
}
