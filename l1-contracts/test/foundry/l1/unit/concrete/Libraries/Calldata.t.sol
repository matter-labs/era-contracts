// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Calldata} from "contracts/vendor/Calldata.sol";

/// @notice Helper contract to test Calldata library functions
/// @dev The Calldata library functions return calldata types, so we need a helper
contract CalldataHelper {
    function getEmptyBytes() external pure returns (bytes calldata) {
        return Calldata.emptyBytes();
    }

    function getEmptyString() external pure returns (string calldata) {
        return Calldata.emptyString();
    }

    function getEmptyBytesLength() external pure returns (uint256) {
        return Calldata.emptyBytes().length;
    }

    function getEmptyStringLength() external pure returns (uint256) {
        return bytes(Calldata.emptyString()).length;
    }
}

/// @notice Unit tests for Calldata library
contract CalldataTest is Test {
    CalldataHelper internal helper;

    function setUp() public {
        helper = new CalldataHelper();
    }

    // ============ emptyBytes Tests ============

    function test_emptyBytes_hasZeroLength() public view {
        uint256 length = helper.getEmptyBytesLength();
        assertEq(length, 0);
    }

    function test_emptyBytes_returnsEmptyCalldata() public view {
        bytes memory result = helper.getEmptyBytes();
        assertEq(result.length, 0);
    }

    // ============ emptyString Tests ============

    function test_emptyString_hasZeroLength() public view {
        uint256 length = helper.getEmptyStringLength();
        assertEq(length, 0);
    }

    function test_emptyString_returnsEmptyCalldata() public view {
        string memory result = helper.getEmptyString();
        assertEq(bytes(result).length, 0);
    }
}
