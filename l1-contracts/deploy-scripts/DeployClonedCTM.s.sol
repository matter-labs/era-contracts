// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {DeployCTMScript} from "./DeployCTM.s.sol";

/// @notice Deploys a CTM while reusing a precomputed `force_deployments_data` blob from the input config.
/// @dev This is intended for "clone an existing CTM as closely as possible" workflows where the chain creation
///      parameters are extracted from an existing CTM and written into the config file ahead of time.
contract DeployClonedCTMScript is DeployCTMScript {
    using stdToml for string;

    bytes internal configuredForceDeploymentsData;

    function run() public virtual override {
        // Kept intentionally empty so callers can choose the bridgehub and reuse flag explicitly.
        return ();
    }

    function runWithBridgehubFromConfig(address bridgehub, bool reuseGovAndAdmin) public {
        console.log("Deploying cloned CTM related contracts");

        runInner(
            "/script-config/config-deploy-cloned-ctm.toml",
            "/script-out/output-deploy-cloned-ctm.toml",
            bridgehub,
            reuseGovAndAdmin
        );
    }

    function initializeConfig(string memory configPath) internal virtual override {
        super.initializeConfig(configPath);

        string memory toml = vm.readFile(configPath);
        if (vm.keyExistsToml(toml, "$.contracts.force_deployments_data")) {
            configuredForceDeploymentsData = toml.readBytes("$.contracts.force_deployments_data");
        } else {
            configuredForceDeploymentsData = bytes("");
        }
    }

    function initializeGeneratedData() internal virtual override {
        if (configuredForceDeploymentsData.length != 0) {
            generatedData.forceDeploymentsData = configuredForceDeploymentsData;
            return;
        }

        super.initializeGeneratedData();
    }
}
