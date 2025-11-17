// SPDX-License-Identifier: MIT
// solhint-disable no-console, gas-custom-errors, state-visibility, no-global-import, one-contract-per-file, gas-calldata-parameters
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "contracts/bridge/BridgeHelper.sol"; // adjust path
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

// A simple ERC20 mock that returns fixed values
contract MockERC20 is IERC20Metadata {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory n, string memory s, uint8 d) {
        _name = n;
        _symbol = s;
        _decimals = d;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    // Unused in this test
    function totalSupply() external pure returns (uint256) {
        return 0;
    }
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

// A mock ERC20 that reverts on one of the calls
contract RevertingERC20 is IERC20Metadata {
    bool shouldRevertSymbol;
    constructor(bool _shouldRevertSymbol) {
        shouldRevertSymbol = _shouldRevertSymbol;
    }

    function name() external pure returns (string memory) {
        revert("name fail");
    }

    function symbol() external view returns (string memory) {
        if (shouldRevertSymbol) {
            revert("symbol fail");
        }
        return "SYM";
    }

    function decimals() external pure returns (uint8) {
        revert("dec fail");
    }

    // Unused ERC20 functions
    function totalSupply() external pure returns (uint256) {
        return 0;
    }
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

contract DataEncodingWrapper {
    function decodeTokenData(
        bytes calldata data
    ) external pure returns (uint256, bytes memory, bytes memory, bytes memory) {
        return DataEncoding.decodeTokenData(data);
    }
}
interface IDataEncodingBridge {
    function decodeTokenData(
        bytes memory data
    ) external pure returns (uint256, bytes memory, bytes memory, bytes memory);
}

contract BridgeHelperTest is Test {
    uint256 constant ORIGIN_CHAIN_ID = 270;

    IDataEncodingBridge dec;

    function setUp() public {
        dec = IDataEncodingBridge(address(new DataEncodingWrapper()));
    }

    function testGetERC20Getters_ForETH() public {
        bytes memory result = BridgeHelper.getERC20Getters(ETH_TOKEN_ADDRESS, ORIGIN_CHAIN_ID);

        // Decode back for assertion
        (uint256 chainId, bytes memory name, bytes memory symbol, bytes memory decimals) = dec.decodeTokenData(result);

        assertEq(chainId, ORIGIN_CHAIN_ID);
        assertEq(abi.decode(name, (string)), "Ether");
        assertEq(abi.decode(symbol, (string)), "ETH");
        assertEq(abi.decode(decimals, (uint8)), 18);
    }

    function testGetERC20Getters_ForERC20() public {
        MockERC20 token = new MockERC20("TokenName", "TKN", 8);
        bytes memory result = BridgeHelper.getERC20Getters(address(token), ORIGIN_CHAIN_ID);

        (uint256 chainId, bytes memory name, bytes memory symbol, bytes memory decimals) = dec.decodeTokenData(result);

        assertEq(chainId, ORIGIN_CHAIN_ID);
        assertEq(abi.decode(name, (string)), "TokenName");
        assertEq(abi.decode(symbol, (string)), "TKN");
        assertEq(abi.decode(decimals, (uint8)), 8);
    }

    function testGetERC20Getters_WithReverts() public {
        RevertingERC20 token = new RevertingERC20(false);
        bytes memory result = BridgeHelper.getERC20Getters(address(token), ORIGIN_CHAIN_ID);

        (uint256 chainId, bytes memory name, bytes memory symbol, bytes memory decimals) = dec.decodeTokenData(result);

        assertEq(chainId, ORIGIN_CHAIN_ID);
        assertEq(name.length, 0); // name reverted → empty bytes
        assertEq(abi.decode(symbol, (string)), "SYM"); // symbol ok
        assertEq(decimals.length, 0); // decimals reverted → empty bytes
    }
    function testGetERC20Getters_WithAllReverts() public {
        RevertingERC20 token = new RevertingERC20(true);
        bytes memory result = BridgeHelper.getERC20Getters(address(token), ORIGIN_CHAIN_ID);

        (uint256 chainId, bytes memory name, bytes memory symbol, bytes memory decimals) = dec.decodeTokenData(result);

        assertEq(chainId, ORIGIN_CHAIN_ID);
        assertEq(name.length, 0); // name reverted → empty bytes
        assertEq(symbol.length, 0); // symbol reverted → empty bytes
        assertEq(decimals.length, 0); // decimals reverted → empty bytes
    }
    function testGetERC20Getters_InvalidAddress() public view {
        // Use an address with no code
        address invalidToken = address(0xdead); // nothing deployed here

        bytes memory result = BridgeHelper.getERC20Getters(invalidToken, ORIGIN_CHAIN_ID);

        // Decode the token data using DataEncoding
        (uint256 chainId, bytes memory name, bytes memory symbol, bytes memory decimals) = dec.decodeTokenData(result);

        // Assert expected behavior
        assertEq(chainId, ORIGIN_CHAIN_ID);
        assertEq(name.length, 0, "name should be empty");
        assertEq(symbol.length, 0, "symbol should be empty");
        assertEq(decimals.length, 0, "decimals should be empty");
    }
}
