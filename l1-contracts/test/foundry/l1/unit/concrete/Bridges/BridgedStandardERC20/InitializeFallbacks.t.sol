// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";

contract BridgedStandardERC20_InitializeFallbacks_Test is Test {
    BridgedStandardERC20 implementation;
    address originToken = address(0xBEEF);
    bytes32 assetId = keccak256(abi.encode("assetId"));

    function setUp() public {
        implementation = new BridgedStandardERC20();
    }

    function _encodeTokenData(
        bytes memory nameBytes,
        bytes memory symbolBytes,
        bytes memory decimalsBytes
    ) internal pure returns (bytes memory) {
        return
            DataEncoding.encodeTokenData({
                _chainId: 1,
                _name: nameBytes,
                _symbol: symbolBytes,
                _decimals: decimalsBytes
            });
    }

    function _deployProxy() internal returns (BridgedStandardERC20 token) {
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), bytes(""));
        token = BridgedStandardERC20(address(proxy));
    }

    function _deployAndInit(bytes memory tokenData) internal returns (BridgedStandardERC20 token) {
        token = _deployProxy();
        token.bridgeInitialize(assetId, originToken, tokenData);
    }

    function test_IgnoreName_FallbacksAndGetters() public {
        bytes memory invalid = hex"1234"; // not ABI-encoded string/uint8
        bytes memory data = _encodeTokenData({
            nameBytes: invalid,
            symbolBytes: abi.encode("SYM"),
            decimalsBytes: abi.encode(uint8(6))
        });

        BridgedStandardERC20 token = _deployAndInit(data);

        // name() should revert when ignoreName = true
        vm.expectRevert();
        token.name();

        // others return provided values
        assertEq(keccak256(bytes(token.symbol())), keccak256(bytes("SYM")));
        assertEq(token.decimals(), 6);
    }

    function test_IgnoreSymbol_FallbacksAndGetters() public {
        bytes memory invalid = hex"1234";
        bytes memory data = _encodeTokenData({
            nameBytes: abi.encode("NiceName"),
            symbolBytes: invalid,
            decimalsBytes: abi.encode(uint8(18))
        });

        BridgedStandardERC20 token = _deployAndInit(data);

        assertEq(keccak256(bytes(token.name())), keccak256(bytes("NiceName")));
        vm.expectRevert();
        token.symbol();
        assertEq(token.decimals(), 18);
    }

    function test_IgnoreDecimals_FallbacksAndGetters() public {
        bytes memory invalid = hex"1234";
        bytes memory data = _encodeTokenData({
            nameBytes: abi.encode("N"),
            symbolBytes: abi.encode("S"),
            decimalsBytes: invalid
        });

        BridgedStandardERC20 token = _deployAndInit(data);

        assertEq(keccak256(bytes(token.name())), keccak256(bytes("N")));
        assertEq(keccak256(bytes(token.symbol())), keccak256(bytes("S")));
        vm.expectRevert();
        token.decimals();
    }

    function test_AllInvalid_AllGettersRevert() public {
        bytes memory invalid = hex"1234";
        bytes memory data = _encodeTokenData(invalid, invalid, invalid);
        BridgedStandardERC20 token = _deployAndInit(data);

        vm.expectRevert();
        token.name();
        vm.expectRevert();
        token.symbol();
        vm.expectRevert();
        token.decimals();
    }
}
