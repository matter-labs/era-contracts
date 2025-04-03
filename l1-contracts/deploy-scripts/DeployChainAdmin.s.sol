// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";

import {Utils} from "./Utils.sol";

contract DeployChainAdmin is Script {
    using stdToml for string;

    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct DeploymentConfig {
        address owner;
        address tokenMultiplierSetter;
        bytes32 create2FactorySalt;
        address chainAdmin;
    }

    DeploymentConfig public config;

    function run() public {
        initializeConfig();

        deployChainAdmin();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-chain-admin.toml");
        string memory toml = vm.readFile(path);

        config.owner = toml.readAddress("$.owner");
        config.tokenMultiplierSetter = toml.readAddress("$.token_multiplier_setter");
        config.create2FactorySalt = toml.readBytes32("$.create2_factory_salt");
    }

    function deployChainAdmin() internal {
        bytes memory bytecode = abi.encodePacked(
            type(ChainAdminOwnable).creationCode,
            abi.encode(config.owner, config.tokenMultiplierSetter)
        );
        console.log("Owner:");
        console.log(config.owner);
        console.log("Constructor args:");
        console.logBytes(abi.encode(config.owner, config.tokenMultiplierSetter));
        address chainAdmin = Utils.deployViaCreate2(
            bytecode,
            config.create2FactorySalt,
            DETERMINISTIC_CREATE2_ADDRESS
        );
        console.log("ChainAdmin deployed at:", chainAdmin);
        config.chainAdmin = chainAdmin;
    }
}
