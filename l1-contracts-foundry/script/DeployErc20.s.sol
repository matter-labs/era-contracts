// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "./Utils.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IZkSyncStateTransition} from "contracts/state-transition/chain-interfaces/IZkSyncStateTransition.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncStateTransitionStorage.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";

contract RegisterHyperchainScript is Script {
    using stdToml for string;

    struct Config {
        TokenDescription[] tokens;
        address deployerAddress;
        address create2FactoryAddr;
        bytes32 create2FactorySalt;
    }

    struct TokenDescription {
        address addr;
        string name;
        string symbol;
        uint256 decimals;
        string implementation;
        uint256 mint;
    }

    Config config;

    function run() public {
        console.log("Deploying ERC20 Tokens");

        initializeConfig();
        deployTokens();
    }

    function initializeConfig() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-deploy-erc20.toml");
        string memory toml = vm.readFile(path);

        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.create2FactoryAddr = vm.parseTomlAddress(toml, "$.create2_factory_addr");
        config.create2FactorySalt = vm.parseTomlBytes32(toml, "$.create2_factory_salt");
        string[] memory tokens = vm.parseTomlKeys(toml, "$.tokens");

        for (uint256 i = 0; i < tokens.length; i++) {
            TokenDescription memory token;
            string memory key = string.concat("$.tokens.", tokens[i]);
            token.name = toml.readString(string.concat(key, ".name"));
            token.symbol = toml.readString(string.concat(key, ".symbol"));
            token.decimals = toml.readUint(string.concat(key, ".decimals"));
            token.implementation = toml.readString(string.concat(key, ".implementation"));
            token.mint = toml.readUint(string.concat(key, ".mint"));

            config.tokens.push(token);
        }
    }

    function deployTokens() internal {
        for (uint256 i = 0; i < config.tokens.length; i++) {
            TokenDescription memory token = config.tokens[i];
            console.log("Deploying token:", token.name);
            address tokenAddress = deployErc20(
                token.name,
                token.symbol,
                token.decimals,
                token.implementation,
                token.mint
            );
            console.log("Token deployed at:", tokenAddress);
            token.addr = tokenAddress;
        }
    }

    function deployErc20(
        string memory name,
        string memory symbol,
        uint256 decimals,
        string memory implementation,
        uint256 mint
    ) internal returns (address) {
        bytes memory args = abi.encode(name, symbol, decimals);
        bytes memory bytecode = abi.encodePacked(vm.getCode(implementation), args);

        address tokenAddress = deployViaCreate2(bytecode);

        if (mint > 0) {
            vm.broadcast();
            tokenAddress.call(abi.encodeWithSignature("mint(address,uint256)", config.deployerAddress, mint));
        }

        return tokenAddress;
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return Utils.deployViaCreate2(_bytecode, config.create2FactorySalt, config.create2FactoryAddr);
    }
}
