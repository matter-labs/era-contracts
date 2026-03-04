// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {DeployL1CoreContractsScript} from "deploy-scripts/DeployL1CoreContracts.s.sol";
import {StateTransitionDeployedAddresses} from "deploy-scripts/Utils.sol";

contract DeployL1CoreContractsIntegrationScript is Script, DeployL1CoreContractsScript {
    using stdToml for string;

    function test() internal virtual override {}
}
