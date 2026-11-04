// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2DACommitmentScheme} from "contracts/common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IRollupDAManager {
    function isAllowedDAConfiguration(
        address l1DAValidator,
        L2DACommitmentScheme l2DAValidator
    ) external view returns (bool);
    function updateDAPair(address l1DAValidator, L2DACommitmentScheme l2DACommitmentScheme, bool status) external;
    function transferOwnership(address newOwner) external;
}
