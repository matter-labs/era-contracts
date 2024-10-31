// SPDX-License-Identifier: MIT
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

    // This function should be called by the owner to accept the admin role
    function governanceAcceptOwner(address governor, address target) public {
        Ownable2Step adminContract = Ownable2Step(target);
        bytes memory data = abi.encodeCall(adminContract.acceptOwnership, ());
        //Only execute if the operation does not exist yet
        if (!Utils.governanceOperationExists(governor, target, 0, data, bytes32(0), bytes32(0))) {
            Utils.executeUpgrade({
                _governor: governor,
                _salt: bytes32(0),
                _target: target,
                _data: data,
                _value: 0,
                _delay: 0
            });
        }
    }

    // This function should be called by the owner to accept the admin role
    function governanceAcceptAdmin(address governor, address target) public {
        IZkSyncHyperchain adminContract = IZkSyncHyperchain(target);
        bytes memory data = abi.encodeCall(adminContract.acceptAdmin, ());
        //Only execute if the operation does not exist yet
        if (!Utils.governanceOperationExists(governor, target, 0, data, bytes32(0), bytes32(0))) {
            Utils.executeUpgrade({
                _governor: governor,
                _salt: bytes32(0),
                _target: target,
                _data: data,
                _value: 0,
                _delay: 0
            });
        }
    }

    // This function should be called by the owner to accept the admin role
    function chainAdminAcceptAdmin(ChainAdmin chainAdmin, address target) public {
        IZkSyncHyperchain adminContract = IZkSyncHyperchain(target);
        bool adminIsDifferent = false;
        address currentAdmin;

        // Attempt to call admin() using a low-level call
        (bool success, bytes memory result) = target.call(abi.encodeWithSignature("admin()"));

        if (success) {
            // Decode the result to get the current admin address
            currentAdmin = abi.decode(result, (address));
        } else {
            // If admin() fails, try calling getAdmin() instead
            (success, result) = target.call(abi.encodeWithSignature("getAdmin()"));
            require(success, "Both admin() and getAdmin() calls failed");

            // Decode the result to get the current admin address
            currentAdmin = abi.decode(result, (address));
        }

        // Check if the current admin is different from the expected chainAdmin
        if (currentAdmin != address(chainAdmin)) {
            adminIsDifferent = true;
        }

        // Proceed with multicall if the admin is different
        if (adminIsDifferent) {
            IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](1);
            calls[0] = IChainAdmin.Call({
                target: target,
                value: 0,
                data: abi.encodeCall(adminContract.acceptAdmin, ())
            });

            vm.startBroadcast();
            chainAdmin.multicall(calls, true);
            vm.stopBroadcast();
        }
    }

    // This function should be called by the owner to update token multiplier setter role
    function chainSetTokenMultiplierSetter(address chainAdmin, address target) public {
        IChainAdmin admin = IChainAdmin(chainAdmin);

        vm.startBroadcast();
        admin.setTokenMultiplierSetter(target);
        vm.stopBroadcast();
    }
}
