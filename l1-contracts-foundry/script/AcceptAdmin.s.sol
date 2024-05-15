// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Utils} from "./Utils.sol";

contract AcceptAdmin is Script {
    using stdToml for string;

    // This function should be called by the owner to accept the admin role
    function run() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-accept-admin.toml");
        string memory toml = vm.readFile(path);
        address admin = toml.readAddress("$.target_addr");
        address governor = toml.readAddress("$.governor");
        Ownable2Step adminContract = Ownable2Step(admin);

        Utils.executeUpgrade({
            _governor: governor,
            _salt: bytes32(0),
            _target: admin,
            _data: abi.encodeCall(adminContract.acceptOwnership, ()),
            _value: 0,
            _delay: 0
        });
    }
}
