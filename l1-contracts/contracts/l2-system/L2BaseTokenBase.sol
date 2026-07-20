// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2BaseTokenBase} from "./interfaces/IL2BaseTokenBase.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "../common/L1ContractErrors.sol";

/**
 * @title L2BaseTokenBase
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Abstract base contract for the Era and ZK OS L2 base-token implementations: shared storage
 * layout and access control. See {protocol-docs/bridging.md}.
 * @dev Pre-V31 storage variables are declared here because they predate the V31 upgrade; the storage
 * gap allows adding new shared variables in future upgrades.
 */
abstract contract L2BaseTokenBase is IL2BaseTokenBase {
    /// @notice Ensures that only the ComplexUpgrader can call the function.
    modifier onlyComplexUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice The balances of the users.
    /// @dev Only used by the Era implementation. Declared in the base contract because it existed prior to V31.
    mapping(address account => uint256 balance) internal eraAccountBalance;

    /// @notice Deprecated: the old (Era-only) total-supply variable.
    /// @dev After V31 `totalSupply` is derived from the BaseTokenHolder's balance; this is only read to
    /// account for the pre-V31 supply.
    // slither-disable-next-line uninitialized-state
    uint256 internal __DEPRECATED_totalSupply;

    /// @notice Whether initL2 has already been called.
    bool internal baseTokenHolderBalanceInitialized;

    /// @notice The chain ID of L1.
    uint256 public L1_CHAIN_ID;

    /// @dev Storage gap to allow adding new shared storage variables in future upgrades.
    uint256[46] private __gap;
}
