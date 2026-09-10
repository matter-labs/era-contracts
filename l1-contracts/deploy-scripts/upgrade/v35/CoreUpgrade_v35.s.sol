// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Core (ecosystem) side of the v35 upgrade — the first REGISTRY-DRIVEN edge after the
///         v34 bootstrap, and deliberately a small one: a fresh `L1MessageRoot` implementation is
///         the whole ecosystem leg. The base pipeline pins it in a `CoreRegistry`; the CTM prepare's
///         transition names that registry and `CTMUpgradeExecutor.stage1` applies it through the
///         bound ecosystem executor. This prepare emits no governance call of its own.
contract CoreUpgrade_v35 is DefaultCoreUpgrade {
    /// @notice The one ecosystem implementation this edge swaps.
    function deployNewEcosystemContractsL1() public virtual override {
        coreAddresses.bridgehub.implementations.messageRoot = deploySimpleContract("L1MessageRoot");
    }

    /// @notice Override to properly set deployerAddress in upgrade context.
    /// @dev In Forge scripts with vm.broadcast(), msg.sender is the script address, but the
    ///      actual deployer is the broadcast key — same fix as every upgrade script needs.
    function initializeL1CoreUtilsConfig() internal override {
        super.initializeL1CoreUtilsConfig();
        config.deployerAddress = getBroadcasterAddress();
        console.log("Overriding deployerAddress in upgrade context:", config.deployerAddress);
    }
}
