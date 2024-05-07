// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Test} from "forge-std/Test.sol";

import {DeployErc20Script} from "../../../scripts-rs/script/DeployErc20.s.sol";

contract TokenDeployer is Test {
    address[] tokens;
    DeployErc20Script private deployScript;

    function deployTokens() internal {
        deployScript = new DeployErc20Script();
        deployScript.run();
        tokens = deployScript.getTokensAddresses();
    }
}
