// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Utils} from "./Utils.sol";

contract AcceptAdmin is Script {
    using stdToml for string;

    // This function should be called by the owner to accept the admin role
    function run() public {
        console.log("Accept admin Hyperchain");
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-accept-admin.toml");
        string memory toml = vm.readFile(path);
        address admin = toml.readAddress("$.target_addr");
        address governor = toml.readAddress("$.governor");
        console.log(governor);
        Ownable2Step adminContract = Ownable2Step(admin);
        Utils.executeUpgrade(governor, bytes32(0), admin, abi.encodeCall(adminContract.acceptOwnership, ()), 0, 0);
    }
}
