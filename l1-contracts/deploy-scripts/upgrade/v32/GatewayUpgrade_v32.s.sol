// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script} from "forge-std/Script.sol";

import {L2_GENESIS_UPGRADE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2GenesisUpgrade} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {DefaultGatewayUpgrade} from "../default-upgrade/DefaultGatewayUpgrade.s.sol";

/// @notice Script used for the gateway-side v32 (atomic interop) upgrade flow.
/// @dev Like the L1 side (see `CTMUpgrade_v32`), the gateway upgrade is storage-compatible with
///      no migration and no additional factory dependencies. The upgrade transaction delegates to
///      the `L2GenesisUpgrade` built-in through the universal ComplexUpgrader path (used by both
///      VMs from v32 onwards); ecosystem-level arguments are zero on the gateway, matching the
///      v31 gateway flow.
contract GatewayUpgrade_v32 is Script, DefaultGatewayUpgrade {
    function getV32L2UpgradeCalldata() internal view returns (bytes memory) {
        return abi.encodeCall(IL2GenesisUpgrade.genesisUpgrade, (config.isZKsyncOS, 0, address(0), "", ""));
    }

    function getEraL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal view override returns (address, bytes memory) {
        return getComplexUpgraderTargetAndData(_deployments, L2_GENESIS_UPGRADE_ADDR, getV32L2UpgradeCalldata());
    }

    function getZKsyncOSL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal view override returns (address, bytes memory) {
        return getComplexUpgraderTargetAndData(_deployments, L2_GENESIS_UPGRADE_ADDR, getV32L2UpgradeCalldata());
    }
}
