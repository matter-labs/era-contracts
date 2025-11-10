// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {L1InteropHandler} from "./L1InteropHandler.sol";
import {L2InteropCenter} from "./L2InteropCenter.sol";

contract DeployContracts is Script {
    using stdToml for string;

    function run(string memory l1RpcUrl, string memory l2RpcUrl) public {
        console.log("Deploying contracts");

        vm.createSelectFork(l1RpcUrl);
        L1InteropHandler l1InteropHandler = new L1InteropHandler();
        l1InteropHandler.setL2InteropCenterAddress(address(l2InteropCenter));
        console.log("L1InteropHandler deployed to", address(l1InteropHandler));

        vm.createSelectFork(l2RpcUrl);
        L2InteropCenter l2InteropCenter = new L2InteropCenter();
        l2InteropCenter.setL1InteropHandlerAddress(address(l1InteropHandler));
        console.log("L2InteropCenter deployed to", address(l2InteropCenter));
    }
}