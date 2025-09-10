// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {StateTransitionDeployedAddresses, Utils, FacetCut} from "../Utils.sol";
import {DefaultEcosystemUpgrade} from "../upgrade/DefaultEcosystemUpgrade.s.sol";

/// @notice Script used for v28_1 upgrade flow
contract EcosystemUpgrade_v28_1_zk_os is Script, DefaultEcosystemUpgrade {
    using stdToml for string;

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(
            vm.envString("ZK_OS_V28_1_UPGRADE_ECOSYSTEM_INPUT"),
            vm.envString("ZK_OS_V28_1_UPGRADE_ECOSYSTEM_OUTPUT")
        );
        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
    }

    function deployNewEcosystemContracts() public override {
        require(upgradeConfig.initialized, "Not initialized");

        instantiateCreate2Factory();

        deployVerifiers();
        deployUpgradeStageValidator();
        (addresses.stateTransition.defaultUpgrade) = deployUsedUpgradeContract();
        upgradeAddresses.upgradeTimer = deploySimpleContract("GovernanceUpgradeTimer", false);
        upgradeConfig.ecosystemContractsDeployed = true;
    }

    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (FacetCut[] memory facetCuts) {
        facetCuts = new FacetCut[](0);
    }
}
