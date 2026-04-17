// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {GetDiamondCutData} from "../utils/GetDiamondCutData.sol";

/// @notice Writes CTM `forceDeploymentsData` (from `NewChainCreationParams` logs) to a TOML fragment
/// for building `gateway-vote-preparation` input. Set env `FORCE_DEPLOYMENTS_DUMP_TOML_REL_PATH`
/// to a path relative to project root (e.g. `/script-out/force-deployments-dump.toml`).
contract DumpForceDeploymentsForGateway is Script {
    function run(address _ctm) external {
        (, bytes memory forceDeploymentsData) = GetDiamondCutData.getDiamondCutAndForceDeployment(_ctm);

        string memory root = vm.projectRoot();
        string memory rel = vm.envString("FORCE_DEPLOYMENTS_DUMP_TOML_REL_PATH");
        string memory path = string.concat(root, rel);

        string memory toml = vm.serializeBytes("root", "force_deployments_data", forceDeploymentsData);
        vm.writeToml(toml, path);
    }
}
