// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {DeployErc20Script} from "../../../deploy-scripts/DeployErc20.s.sol";
import {TestnetERC20Token} from "../../../contracts/dev-contracts/TestnetERC20Token.sol";

contract TokenDeployTest is Test {
    using stdToml for string;

    struct ConfigOutput {
        TokenDescriptionOutput[] tokens;
        address deployerAddress;
        address create2FactoryAddr;
        bytes32 create2FactorySalt;
    }

    struct TokenDescriptionOutput {
        address addr;
        uint256 decimals;
        string implementation;
        uint256 mint;
        string name;
        string symbol;
    }

    struct ConfigInput {
        TokenDescriptionInput[] tokens;
        address deployerAddress;
        address create2FactoryAddr;
        bytes32 create2FactorySalt;
    }

    struct TokenDescriptionInput {
        uint256 decimals;
        uint256 mint;
        string name;
        string symbol;
    }

    ConfigOutput configOutput;
    address[] addresses;
    DeployErc20Script private deployScript;

    ConfigInput configInput;
    TestnetERC20Token testnetToken;

    function setUp() public {

        deployScript = new DeployErc20Script();
        deployScript.run();
        addresses = deployScript.getTokensAddresses();

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-deploy-erc20.toml");
        string memory toml = vm.readFile(path);
        string[] memory tokens = vm.parseTomlKeys(toml, "$.tokens");
        for (uint256 i = 0; i < tokens.length; i++) {
            TokenDescriptionOutput memory token;
            string memory key = string.concat("$.tokens.", tokens[i]);
            token.addr = toml.readAddress(string.concat(key, ".address"));
            token.decimals = toml.readUint(string.concat(key, ".decimals"));
            token.implementation = toml.readString(string.concat(key, ".implementation"));
            token.mint = toml.readUint(string.concat(key, ".mint"));
            token.name = toml.readString(string.concat(key, ".name"));
            token.symbol = toml.readString(string.concat(key, ".symbol"));

            configOutput.tokens.push(token);    
        }

        path = string.concat(root, "/deploy-script-config-template/config-deploy-erc20.toml");
        toml = vm.readFile(path);
        string[] memory testnetTokens = vm.parseTomlKeys(toml, "$.tokens");
        for (uint256 i = 0; i < testnetTokens.length; i++) {
            TokenDescriptionInput memory token;
            string memory key = string.concat("$.tokens.", testnetTokens[i]);
            token.name = toml.readString(string.concat(key, ".name"));
            token.symbol = toml.readString(string.concat(key, ".symbol"));
            token.decimals = toml.readUint(string.concat(key, ".decimals"));
            token.mint = toml.readUint(string.concat(key, ".mint"));

            configInput.tokens.push(token);
        }

        testnetToken = new TestnetERC20Token(configInput.tokens[0].name, configInput.tokens[0].symbol, uint8(configInput.tokens[0].decimals));
    }

    function test_checkTokenAddresses() public {
        address token_01_addr = addresses[0];
        address token_01_addr_check = configOutput.tokens[0].addr;
        assertEq(token_01_addr, token_01_addr_check);

        address token_02_addr = addresses[1];
        address token_02_addr_check = configOutput.tokens[1].addr;
        assertEq(token_02_addr, token_02_addr_check);
    }

    function test_checkTestnetERC20TokenContract() public {
        string memory token01Name = testnetToken.name();
        string memory token01NameCheck = configOutput.tokens[0].name;
        assertEq(token01Name, token01NameCheck);

        string memory token01Symbol = testnetToken.symbol();
        string memory token01SymbolCheck = configOutput.tokens[0].symbol;
        assertEq(token01Symbol, token01SymbolCheck);

        uint8 token01Decimals = testnetToken.decimals();
        uint8 token01DecimalsCheck = configOutput.tokens[0].decimals;
        assertEq(token01Decimals, token01DecimalsCheck);
    }

    function test_checkTestnetERC20Mint() public {
        //deploy wallet to get address for mint function
        bool mintResult = testnetToken.mint(0x36615Cf349d7F6344891B1e7CA7C72883F5dc049, 5);
        assertTrue(mintResult);
    }
}