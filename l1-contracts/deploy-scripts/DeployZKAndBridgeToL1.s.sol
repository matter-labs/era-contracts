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
import {MintFailed} from "./ZkSyncScriptErrors.sol";

contract DeployZKScript is Script {
    using stdToml for string;

    struct Config {
        TokenDescription zkToken;
        address deployerAddress;
        address[] additionalAddressesForMinting;
        address create2FactoryAddr;
        bytes32 create2FactorySalt;
        uint256 chainId;
        address l1SharedBridge;
        address bridgehub;
    }

    struct TokenDescription {
        address addr;
        string name;
        string symbol;
        uint256 decimals;
        string implementation;
        uint256 mint;
    }

    Config internal config;

    function run() public {
        console.log("Deploying ZK Token");

        initializeConfig();
        deployZkToken();
        saveOutput();
    }

    function getTokenAddress() public view returns (address) {
        return config.zkToken.addr;
    }

    function initializeConfig() internal {
        config.deployerAddress = msg.sender;

        string memory root = vm.projectRoot();

        // Grab config from output of l1 deployment
        string memory path = string.concat(root, vm.envString("L1_OUTPUT"));
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.create2FactoryAddr = vm.parseTomlAddress(toml, "$.create2_factory_addr");
        config.create2FactorySalt = vm.parseTomlBytes32(toml, "$.create2_factory_salt");

        // Grab config from custom config file
        path = string.concat(root, vm.envString("ZK_TOKEN_CONFIG"));
        toml = vm.readFile(path);
        config.additionalAddressesForMinting = vm.parseTomlAddressArray(toml, "$.additional_addresses_for_minting");

        // Parse the ZK token configuration
        string memory key = "$.tokens.ZK";
        config.zkToken.name = toml.readString(string.concat(key, ".name"));
        config.zkToken.symbol = toml.readString(string.concat(key, ".symbol"));
        config.zkToken.decimals = toml.readUint(string.concat(key, ".decimals"));
        config.zkToken.implementation = toml.readString(string.concat(key, ".implementation"));
        config.zkToken.mint = toml.readUint(string.concat(key, ".mint"));
    }

    function deployZkToken() internal {
        TokenDescription storage token = config.zkToken;
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

    function deployErc20(
        string memory name,
        string memory symbol,
        uint256 decimals,
        string memory implementation,
        uint256 mint,
        address[] storage additionalAddressesForMinting
    ) internal returns (address) {
        // bytes memory args;
        // // WETH9 constructor has no arguments
        // if (keccak256(bytes(implementation)) != keccak256(bytes("WETH9.sol"))) {
        //     args = abi.encode(name, symbol, decimals);
        // }

        // bytes memory bytecode = abi.encodePacked(vm.getCode(implementation), args);

        vm.broadcast();
        TestnetERC20Token token = new TestnetERC20Token(name, symbol, uint8(decimals));
        address tokenAddress = address(token);

        // if (mint > 0) {
        //     vm.broadcast();
        //     additionalAddressesForMinting.push(config.deployerAddress);
        //     uint256 addressMintListLength = additionalAddressesForMinting.length;
        //     for (uint256 i = 0; i < addressMintListLength; ++i) {
        //         (bool success, ) = tokenAddress.call(
        //             abi.encodeWithSignature("mint(address,uint256)", additionalAddressesForMinting[i], mint)
        //         );
        //         if (!success) {
        //             revert MintFailed();
        //         }
        //         console.log("Minting to:", additionalAddressesForMinting[i]);
        //         if (!success) {
        //             revert MintFailed();
        //         }
        //     }
        // }

        return tokenAddress;
    }

    function saveOutput() internal {
        TokenDescription memory token = config.zkToken;
        vm.serializeString(token.symbol, "name", token.name);
        vm.serializeString(token.symbol, "symbol", token.symbol);
        vm.serializeUint(token.symbol, "decimals", token.decimals);
        vm.serializeString(token.symbol, "implementation", token.implementation);
        vm.serializeUintToHex(token.symbol, "mint", token.mint);
        string memory tokenInfo = vm.serializeAddress(token.symbol, "address", token.addr);

        string memory toml = vm.serializeString("root", "tokens", tokenInfo);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-erc20.toml");
        vm.writeToml(toml, path);
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
