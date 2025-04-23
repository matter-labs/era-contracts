// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {NotARestriction} from "../../common/L1ContractErrors.sol";
import {IRestriction, RESTRICTION_MAGIC} from "./IRestriction.sol";

/// @title Restriction validator
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The library which validates whether an address can be a valid restriction
library RestrictionValidator {
    /// @notice Ensures that the provided address implements the restriction interface
    /// @dev Note that it *can not guarantee* that the corresponding address indeed implements
    /// the interface completely or that it is implemented correctly. It is mainly used to
    /// ensure that invalid restrictions can not be accidentally added.
    function validateRestriction(address _restriction) internal view {
        if (IRestriction(_restriction).getSupportsRestrictionMagic() != RESTRICTION_MAGIC) {
            revert NotARestriction(_restriction);
        }
    }
}
