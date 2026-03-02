// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts-v4/utils/Address.sol";

import {L2BaseTokenBase} from "../L2BaseTokenBase.sol";
import {IL2BaseTokenZKOS} from "./interfaces/IL2BaseTokenZKOS.sol";
import {L2_BASE_TOKEN_HOLDER_ADDR, MINT_BASE_TOKEN_HOOK} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {L2_ASSET_TRACKER} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE, SERVICE_TRANSACTION_SENDER} from "../../common/Config.sol";
import {
    BaseTokenHolderMintFailed,
    BaseTokenPreV31TotalSupplyNotSet,
    Unauthorized
} from "../../common/L1ContractErrors.sol";

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
    /// @notice The pre-V31 total supply for ZKOS chains, set by chain admin via service transaction.
    /// @dev On ZKOS chains, pre-V31 total supply was never tracked on-chain. This value is set after
    /// the V31 upgrade so that totalSupply() can be computed correctly.
    // slither-disable-next-line uninitialized-state
    uint256 public zkosPreV31TotalSupply;

    /// @notice Returns the total circulating supply of base tokens.
    /// @dev Computed as: zkosPreV31TotalSupply + (INITIAL_BASE_TOKEN_HOLDER_BALANCE - BaseTokenHolder.balance)
    /// @dev zkosPreV31TotalSupply captures the total supply that existed before the V31 upgrade.
    /// @dev The delta (INITIAL - holder.balance) tracks tokens minted after V31 via the BaseTokenHolder pattern.
    /// @dev Reverts if the pre-V31 total supply has not been set yet to prevent underflow.
    function totalSupply() external view returns (uint256) {
        if (L2_ASSET_TRACKER.needBaseTokenTotalSupplyBackfill()) {
            revert BaseTokenPreV31TotalSupplyNotSet();
        }
        return zkosPreV31TotalSupply + (INITIAL_BASE_TOKEN_HOLDER_BALANCE - L2_BASE_TOKEN_HOLDER_ADDR.balance);
    }

    /// @notice Sets the pre-V31 total supply for ZKOS chains and backfills the L2AssetTracker.
    /// @dev Can only be called via a service transaction (triggered by the chain admin on L1).
    /// @dev Sets zkosPreV31TotalSupply so that totalSupply() returns the correct value,
    /// then calls L2AssetTracker.backFillZKSyncOSBaseTokenV31MigrationData() to register
    /// the base token with the correct total supply.
    /// @param _totalSupply The total supply that existed before the V31 upgrade.
    function setZKsyncOSPreV31TotalSupply(uint256 _totalSupply) external {
        if (msg.sender != SERVICE_TRANSACTION_SENDER) {
            revert Unauthorized(msg.sender);
        }
        zkosPreV31TotalSupply = _totalSupply;

        // Backfill the L2AssetTracker with the correct total supply.
        // This must happen after setting zkosPreV31TotalSupply so that totalSupply()
        // returns the correct value when registerLegacyToken reads it.
        L2_ASSET_TRACKER.backFillZKSyncOSBaseTokenV31MigrationData(_totalSupply);

        emit ZKsyncOSPreV31TotalSupplySet(_totalSupply);
    }

    /// @notice Initializes the BaseTokenHolder's balance during genesis or V31 upgrade.
    /// @dev This function mints 2^127 - 1 tokens to this contract via the mint hook, then transfers all tokens to BaseTokenHolder.
    /// @dev Can only be called by the ComplexUpgrader contract.
    function initializeBaseTokenHolderBalance() external onlyComplexUpgrader {
        // Mint INITIAL_BASE_TOKEN_HOLDER_BALANCE tokens to this contract via the mint hook
        (bool mintSuccess, ) = MINT_BASE_TOKEN_HOOK.call(abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE));
        if (!mintSuccess) {
            revert BaseTokenHolderMintFailed();
        }

        // Transfer all minted tokens to BaseTokenHolder
        Address.sendValue(payable(L2_BASE_TOKEN_HOLDER_ADDR), INITIAL_BASE_TOKEN_HOLDER_BALANCE);
    }
}
