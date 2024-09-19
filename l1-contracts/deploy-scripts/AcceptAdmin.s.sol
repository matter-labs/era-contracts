// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {Utils} from "./Utils.sol";
import {stdToml} from "forge-std/StdToml.sol";

bytes32 constant SET_TOKEN_MULTIPLIER_SETTER_ROLE = keccak256("SET_TOKEN_MULTIPLIER_SETTER_ROLE");

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
    function governanceAcceptAdmin(address governor, address target) public {
        IZKChain adminContract = IZKChain(target);
        Utils.executeUpgrade({
            _governor: governor,
            _salt: bytes32(0),
            _target: target,
            _data: abi.encodeCall(adminContract.acceptAdmin, ()),
            _value: 0,
            _delay: 0
        });
    }

    // This function should be called by the owner to accept the admin role
    function chainAdminAcceptAdmin(ChainAdmin chainAdmin, address target) public {
        IZKChain adminContract = IZKChain(target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: target, value: 0, data: abi.encodeCall(adminContract.acceptAdmin, ())});

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    // This function should be called by the owner to update token multiplier setter role
    function chainSetTokenMultiplierSetter(
        address accessControlRestriction,
        address diamondProxyAddress,
        address setter
    ) public {
        AccessControlRestriction restriction = AccessControlRestriction(accessControlRestriction);

        if (
            restriction.requiredRoles(diamondProxyAddress, IAdmin.setTokenMultiplier.selector) !=
            SET_TOKEN_MULTIPLIER_SETTER_ROLE
        ) {
            vm.startBroadcast();
            restriction.setRequiredRoleForCall(
                diamondProxyAddress,
                IAdmin.setTokenMultiplier.selector,
                SET_TOKEN_MULTIPLIER_SETTER_ROLE
            );
            vm.stopBroadcast();
        }

        if (!restriction.hasRole(SET_TOKEN_MULTIPLIER_SETTER_ROLE, setter)) {
            vm.startBroadcast();
            restriction.grantRole(SET_TOKEN_MULTIPLIER_SETTER_ROLE, setter);
            vm.stopBroadcast();
        }
    }

    function setDAValidatorPair(
        ChainAdmin chainAdmin,
        address target,
        address l1DaValidator,
        address l2DaValidator
    ) public {
        IZKChain adminContract = IZKChain(target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: target,
            value: 0,
            data: abi.encodeCall(adminContract.setDAValidatorPair, (l1DaValidator, l2DaValidator))
        });

        vm.startBroadcast();
        chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }
}
