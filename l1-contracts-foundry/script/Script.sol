// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script as ForgeScript} from "forge-std/Script.sol";

contract Script is ForgeScript {
    uint256 chainId;
    string network;

    function isNetworkLocal() internal view returns (bool) {
        return keccak256(abi.encodePacked(network)) == keccak256(abi.encodePacked("local"));
    }
}
