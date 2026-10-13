// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Core (ecosystem) side of the v36 upgrade — the first REGISTRY-DRIVEN edge after the
///         v35 bootstrap, and deliberately a small one: a fresh `L1MessageRoot` implementation is
///         the whole ecosystem leg. The base pipeline pins it in a `CoreTransition`; the CTM prepare's
///         transition names that registry and the coordinator's stage 1 applies it through the
///         `CoreUpgradeExecutor`. This prepare emits no governance call of its own.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgrade_v36 is DefaultCoreUpgrade {
    /// @notice The one ecosystem implementation this edge swaps.
    function deployNewEcosystemContractsL1() public virtual override {
        coreAddresses.bridgehub.implementations.messageRoot = deploySimpleContract("L1MessageRoot");
    }
}
