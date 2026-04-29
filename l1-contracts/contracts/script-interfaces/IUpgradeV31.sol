// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EcosystemUpgradeParams} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IUpgradeV31 {
    function noGovernancePrepare(EcosystemUpgradeParams memory _params) external;
}
