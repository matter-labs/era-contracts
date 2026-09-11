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
 * @notice Initializes the base-token reserve and reports circulating supply.
 * @dev See {protocol-docs/bridging.md#base-token-handling}.
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

    /// @inheritdoc IL2BaseToken
    // slither-disable-next-line uninitialized-state
    uint256 public override zkosPreV31TotalSupply;

    /// @inheritdoc IL2BaseToken
    function totalSupply() external view override returns (uint256) {
        return zkosPreV31TotalSupply + INITIAL_BASE_TOKEN_HOLDER_BALANCE - L2_BASE_TOKEN_HOLDER_ADDR.balance;
    }

    /// @inheritdoc IL2BaseToken
    function initL2(uint256 _l1ChainId) external override onlyComplexUpgrader {
        if (baseTokenHolderBalanceInitialized) {
            revert BaseTokenHolderAlreadyInitialized();
        }
        baseTokenHolderBalanceInitialized = true;
        L1_CHAIN_ID = _l1ChainId;

        (bool mintSuccess, ) = MINT_BASE_TOKEN_HOOK.call(abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE));
        if (!mintSuccess) {
            revert BaseTokenHolderMintFailed();
        }

        Address.sendValue(payable(L2_BASE_TOKEN_HOLDER_ADDR), INITIAL_BASE_TOKEN_HOLDER_BALANCE);
    }
}
