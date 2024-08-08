// SPDX-License-Identifier: UNLICENSED
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {Utils} from "./Utils.sol";

contract AcceptAdmin is Script {
    using stdToml for string;

    struct Config {
        address admin;
        address governor;
    }

    Config internal config;

    function initConfig() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-accept-admin.toml");
        string memory toml = vm.readFile(path);
        config.admin = toml.readAddress("$.target_addr");
        config.governor = toml.readAddress("$.governor");
    }

    // This function should be called by the owner to accept the admin role
    function acceptOwner() public {
        initConfig();

        Ownable2Step adminContract = Ownable2Step(config.admin);
        Utils.executeUpgrade({
            _governor: config.governor,
            _salt: bytes32(0),
            _target: config.admin,
            _data: abi.encodeCall(adminContract.acceptOwnership, ()),
            _value: 0,
            _delay: 0
        });
    }

    // This function should be called by the owner to accept the admin role
    function acceptAdmin() public {
        initConfig();
        IZkSyncHyperchain adminContract = IZkSyncHyperchain(config.admin);
        Utils.executeUpgrade({
            _governor: config.governor,
            _salt: bytes32(0),
            _target: config.admin,
            _data: abi.encodeCall(adminContract.acceptAdmin, ()),
            _value: 0,
            _delay: 0
        });
    }
}
