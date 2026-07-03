// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";

import {DefaultChainUpgrade} from "../default-upgrade/DefaultChainUpgrade.s.sol";

contract ChainUpgrade_v31 is DefaultChainUpgrade {
    using stdToml for string;
}
