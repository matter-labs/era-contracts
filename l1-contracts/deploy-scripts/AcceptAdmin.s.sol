// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2 as console} from "forge-std/Script.sol";
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

    Config config;

    function run() public {
        initConfig();
        acceptOwner();
        acceptAdmin();
    }

    function initConfig() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-l1.toml");
        string memory toml = vm.readFile(path);
        config.admin = 0x09d1367Ce5E539c5B95ba4aEaCb60779797F9fBa;
        config.governor = toml.readAddress("$.deployed_addresses.governance_addr");
    }

    // This function should be called by the owner to accept the admin role
    function acceptOwner() public {
        console.log("Owner", config.governor);
        console.log("Admin", config.admin);
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
        console.log("Admin");
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
