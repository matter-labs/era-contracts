<<<<<<< HEAD
// SPDX-License-Identifier: UNLICENSED
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
=======
// SPDX-License-Identifier: MIT
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {Utils} from "./Utils.sol";
import {stdToml} from "forge-std/StdToml.sol";

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

<<<<<<< HEAD
    // This function should be called by the owner to accept the owner role
    function acceptOwner() public {
        initConfig();

        Ownable2Step adminContract = Ownable2Step(config.admin);
=======
    // This function should be called by the owner to accept the admin role
    function governanceAcceptOwner(address governor, address target) public {
        Ownable2Step adminContract = Ownable2Step(target);
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
        Utils.executeUpgrade({
            _governor: governor,
            _salt: bytes32(0),
            _target: target,
            _data: abi.encodeCall(adminContract.acceptOwnership, ()),
            _value: 0,
            _delay: 0
        });
    }

    // This function should be called by the owner to accept the admin role
<<<<<<< HEAD
    function acceptAdmin(address payable _admin, address _target) public {
        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(_target);
        ChainAdmin chainAdmin = ChainAdmin(_admin);

        IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](1);
        calls[0] = IChainAdmin.Call({target: _target, value: 0, data: abi.encodeCall(hyperchain.acceptAdmin, ())});

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
=======
    function governanceAcceptAdmin(address governor, address target) public {
        IZkSyncHyperchain adminContract = IZkSyncHyperchain(target);
        Utils.executeUpgrade({
            _governor: governor,
            _salt: bytes32(0),
            _target: target,
            _data: abi.encodeCall(adminContract.acceptAdmin, ()),
            _value: 0,
            _delay: 0
        });
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
    }

    // This function should be called by the owner to accept the admin role
    function chainAdminAcceptAdmin(ChainAdmin chainAdmin, address target) public {
        IZkSyncHyperchain adminContract = IZkSyncHyperchain(target);

        IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](1);
        calls[0] = IChainAdmin.Call({target: target, value: 0, data: abi.encodeCall(adminContract.acceptAdmin, ())});

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    // This function should be called by the owner to update token multiplier setter role
    function chainSetTokenMultiplierSetter(address chainAdmin, address target) public {
        IChainAdmin admin = IChainAdmin(chainAdmin);

        vm.startBroadcast();
        admin.setTokenMultiplierSetter(target);
        vm.stopBroadcast();
    }
}
