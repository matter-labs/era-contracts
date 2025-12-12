// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {DefaultChainUpgrade} from "./default_upgrade/DefaultChainUpgrade.s.sol";

contract ChainUpgrade_v29 is DefaultChainUpgrade {
    using stdToml for string;
}
