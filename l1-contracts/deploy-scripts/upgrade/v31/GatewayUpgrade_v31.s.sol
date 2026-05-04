// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script} from "forge-std/Script.sol";

import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";

import {EraForceDeploymentsLib} from "../default-upgrade/EraForceDeploymentsLib.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
import {DefaultGatewayUpgrade} from "../default-upgrade/DefaultGatewayUpgrade.s.sol";

/// @notice Script used for gateway upgrade flow. Not used in V31, but was used in V29 and will be used in V32.
contract GatewayUpgrade_v31 is Script, DefaultGatewayUpgrade {
    function getAdditionalEraForcedCoreContracts()
        internal
        override
        returns (CoreContract[] memory additionalEraForcedCoreContracts)
    {
        additionalEraForcedCoreContracts = new CoreContract[](1);
        additionalEraForcedCoreContracts[0] = CoreContract.L2V31Upgrade;
    }

    function getL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal view override returns (address, bytes memory) {
        bytes memory l2V31UpgradeCalldata = abi.encodeCall(
            IL2V31Upgrade.upgrade,
            (config.isZKsyncOS, address(0), "", "")
        );

        bytes memory complexUpgraderCalldata;
        if (config.isZKsyncOS) {
            complexUpgraderCalldata = abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (_deployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2V31UpgradeCalldata)
            );
        } else {
            complexUpgraderCalldata = abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (EraForceDeploymentsLib.unwrap(_deployments), L2_VERSION_SPECIFIC_UPGRADER_ADDR, l2V31UpgradeCalldata)
            );
        }

        return (address(L2_COMPLEX_UPGRADER_ADDR), complexUpgraderCalldata);
    }
}
