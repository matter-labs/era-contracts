// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {DeployCTMScript} from "deploy-scripts/ctm/DeployCTM.s.sol";

contract DeployCTMIntegrationScript is Script, DeployCTMScript {
    using stdToml for string;

    function test() internal virtual override {}
}
