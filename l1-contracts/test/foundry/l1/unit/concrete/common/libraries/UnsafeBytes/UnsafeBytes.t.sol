// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {UnsafeBytesTest} from "contracts/dev-contracts/test/UnsafeBytesTest.sol";

contract UnsafeBytesTestTest is Test {
    UnsafeBytesTest private unsafeBytesTest;
    bytes private bytesData;
    address private addr0 = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
    address private addr1 = 0x7aFd58312784ACf80E2ba97Dd84Ff2bADeA9e4A2;
    uint256 private u256 = 0x15;
    uint32 private u321 = 0xffffffff;
    uint32 private u322 = 0x16;
    address private addr2 = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bytes32 private b32 = 0x4845bfb858e60647a4f22f02d3712a20fa6b557288dbe97b6ae719390482ef4b;
    address private addr3 = 0xaBEA9132b05A70803a4E85094fD0e1800777fBEF;

    function setUp() public {
        unsafeBytesTest = new UnsafeBytesTest();
        // solhint-disable-next-line func-named-parameters
        bytesData = abi.encodePacked(addr0, addr1, u256, u321, u322, addr2, b32, addr3);
    }

    function test() public {
        (address a0, uint256 o0) = unsafeBytesTest.readAddress(bytesData, 0);
        assertEq(a0, addr0, "addr0 should be first address");
        assertEq(o0, 20, "offset should be 20");

        (address a1, uint256 o1) = unsafeBytesTest.readAddress(bytesData, o0);
        assertEq(a1, addr1, "addr1 should be second address");
        assertEq(o1, 40, "offset should be 40");

        (uint256 u0, uint256 o2) = unsafeBytesTest.readUint256(bytesData, o1);
        assertEq(u0, u256, "u256 should be third value");
        assertEq(o2, 72, "offset should be 72");

        (uint32 u1, uint256 o3) = unsafeBytesTest.readUint32(bytesData, o2);
        assertEq(u1, u321, "u321 should be fourth value");
        assertEq(o3, 76, "offset should be 76");

        (uint32 u2, uint256 o4) = unsafeBytesTest.readUint32(bytesData, o3);
        assertEq(u2, u322, "u322 should be fifth value");
        assertEq(o4, 80, "offset should be 80");

        (address a2, uint256 o5) = unsafeBytesTest.readAddress(bytesData, o4);
        assertEq(a2, addr2, "addr2 should be sixth address");
        assertEq(o5, 100, "offset should be 100");

        (bytes32 b0, uint256 o6) = unsafeBytesTest.readBytes32(bytesData, o5);
        assertEq(b0, b32, "b32 should be seventh value");
        assertEq(o6, 132, "offset should be 132");

        (address a3, uint256 o7) = unsafeBytesTest.readAddress(bytesData, o6);
        assertEq(a3, addr3, "addr3 should be eighth address");
        assertEq(o7, 152, "offset should be 152");

        assertEq(o7, bytesData.length, "offset should be end of bytes");
    }
}
