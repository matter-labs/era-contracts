// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script} from "forge-std/Script.sol";

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

import {DefaultGatewayUpgrade} from "../default-upgrade/DefaultGatewayUpgrade.s.sol";

/// @notice Script used for the gateway-side v32 (atomic interop) upgrade flow.
/// @dev Like the L1 side (see `CTMUpgrade_v32`), the gateway upgrade is storage-compatible with
///      no migration: no additional factory dependencies and no L2 delegate — the upgrade
///      transaction only force-deploys the new bytecode set through the universal
///      ComplexUpgrader path (used by both VMs from v32 onwards).
contract GatewayUpgrade_v32 is Script, DefaultGatewayUpgrade {
    function getEraL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal view override returns (address, bytes memory) {
        return getComplexUpgraderTargetAndData(_deployments, address(0), "");
    }

    // ZKsyncOS keeps the base behavior (universal path, no delegate).
}
