// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
// solhint-disable no-unused-import
import {WETH9} from "contracts/dev-contracts/WETH9.sol";

import {Utils} from "./Utils.sol";

contract DeployErc20Script is Script {
    using stdToml for string;

    struct Config {
        TokenDescription[] tokens;
        address deployerAddress;
        address[] additionalAddressesForMinting;
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
        saveOutput();
    }

    function initializeConfig() internal {
        config.deployerAddress = msg.sender;

        string memory root = vm.projectRoot();

        // Grab config from output of l1 deployment
        string memory path = string.concat(root, "/script-out/output-deploy-l1.toml");
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.create2FactoryAddr = vm.parseTomlAddress(toml, "$.create2_factory_addr");
        config.create2FactorySalt = vm.parseTomlBytes32(toml, "$.create2_factory_salt");

        // Grab config from custom config file
        path = string.concat(root, "/script-config/config-deploy-erc20.toml");
        toml = vm.readFile(path);
        config.additionalAddressesForMinting = vm.parseTomlAddressArray(toml, "$.additional_addresses_for_minting");

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
            TokenDescription storage token = config.tokens[i];
            console.log("Deploying token:", token.name);
            address tokenAddress = deployErc20({
                name: token.name,
                symbol: token.symbol,
                decimals: token.decimals,
                implementation: token.implementation,
                mint: token.mint,
                additionalAddressesForMinting: config.additionalAddressesForMinting
            });
            console.log("Token deployed at:", tokenAddress);
            token.addr = tokenAddress;
        }
    }

    function deployErc20(
        string memory name,
        string memory symbol,
        uint256 decimals,
        string memory implementation,
        uint256 mint,
        address[] storage additionalAddressesForMinting
    ) internal returns (address) {
        bytes memory args;
        // WETH9 constructor has no arguments
        if (keccak256(bytes(implementation)) != keccak256(bytes("WETH9.sol"))) {
            args = abi.encode(name, symbol, decimals);
        }

        bytes memory bytecode = abi.encodePacked(vm.getCode(implementation), args);

        address tokenAddress = deployViaCreate2(bytecode);

        if (mint > 0) {
            vm.broadcast();
            additionalAddressesForMinting.push(config.deployerAddress);
            for (uint256 i = 0; i < additionalAddressesForMinting.length; i++) {
                (bool success, ) = tokenAddress.call(
                    abi.encodeWithSignature("mint(address,uint256)", additionalAddressesForMinting[i], mint)
                );
                require(success, "Mint failed");
                console.log("Minting to:", additionalAddressesForMinting[i]);
            }
        }

        return tokenAddress;
    }

    function saveOutput() internal {
        string memory tokens = "";
        for (uint256 i = 0; i < config.tokens.length; i++) {
            TokenDescription memory token = config.tokens[i];
            vm.serializeString(token.symbol, "name", token.name);
            vm.serializeString(token.symbol, "symbol", token.symbol);
            vm.serializeUint(token.symbol, "decimals", token.decimals);
            vm.serializeString(token.symbol, "implementation", token.implementation);
            vm.serializeUintToHex(token.symbol, "mint", token.mint);
            string memory tokenInfo = vm.serializeAddress(token.symbol, "address", token.addr);

            tokens = vm.serializeString("tokens", token.symbol, tokenInfo);
        }

        string memory toml = vm.serializeString("root", "tokens", tokens);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-erc20.toml");
        vm.writeToml(toml, path);
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return Utils.deployViaCreate2(_bytecode, config.create2FactorySalt, config.create2FactoryAddr);
    }
}
