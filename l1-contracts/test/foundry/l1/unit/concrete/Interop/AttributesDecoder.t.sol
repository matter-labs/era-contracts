// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AttributesDecoder} from "contracts/interop/AttributesDecoder.sol";

/// @notice Wrapper contract to test library functions with calldata
contract AttributesDecoderWrapper {
    function decodeUint256(bytes calldata _data) external pure returns (uint256) {
        return AttributesDecoder.decodeUint256(_data);
    }

    function decodeInteroperableAddress(bytes calldata _data) external pure returns (bytes memory) {
        return AttributesDecoder.decodeInteroperableAddress(_data);
    }
}

/// @notice Unit tests for AttributesDecoder library
contract AttributesDecoderTest is Test {
    AttributesDecoderWrapper public wrapper;

    function setUp() public {
        wrapper = new AttributesDecoderWrapper();
    }

    // ============ decodeUint256 Tests ============

    function test_decodeUint256_basicValue() public view {
        uint256 value = 12345;
        // First 4 bytes are selector (ignored), followed by encoded uint256
        bytes memory data = abi.encodePacked(bytes4(0x12345678), abi.encode(value));

        uint256 result = wrapper.decodeUint256(data);

        assertEq(result, value);
    }

    function test_decodeUint256_zeroValue() public view {
        uint256 value = 0;
        bytes memory data = abi.encodePacked(bytes4(0xaabbccdd), abi.encode(value));

        uint256 result = wrapper.decodeUint256(data);

        assertEq(result, value);
    }

    function test_decodeUint256_maxValue() public view {
        uint256 value = type(uint256).max;
        bytes memory data = abi.encodePacked(bytes4(0x00000000), abi.encode(value));

        uint256 result = wrapper.decodeUint256(data);

        assertEq(result, value);
    }

    function test_decodeUint256_ignoresSelector() public view {
        uint256 value = 999;

        // Different selectors should give same result
        bytes memory data1 = abi.encodePacked(bytes4(0x11111111), abi.encode(value));
        bytes memory data2 = abi.encodePacked(bytes4(0x22222222), abi.encode(value));

        assertEq(wrapper.decodeUint256(data1), wrapper.decodeUint256(data2));
    }

    // ============ decodeInteroperableAddress Tests ============

    function test_decodeInteroperableAddress_basicValue() public view {
        bytes memory addressData = hex"deadbeefcafe";
        bytes memory data = abi.encodePacked(bytes4(0x12345678), abi.encode(addressData));

        bytes memory result = wrapper.decodeInteroperableAddress(data);

        assertEq(result, addressData);
    }

    function test_decodeInteroperableAddress_emptyAddress() public view {
        bytes memory addressData = "";
        bytes memory data = abi.encodePacked(bytes4(0xaabbccdd), abi.encode(addressData));

        bytes memory result = wrapper.decodeInteroperableAddress(data);

        assertEq(result.length, 0);
    }

    function test_decodeInteroperableAddress_20ByteAddress() public view {
        bytes memory addressData = abi.encodePacked(address(0x1234567890AbcdEF1234567890aBcdef12345678));
        bytes memory data = abi.encodePacked(bytes4(0x00000000), abi.encode(addressData));

        bytes memory result = wrapper.decodeInteroperableAddress(data);

        assertEq(result, addressData);
        assertEq(result.length, 20);
    }

    function test_decodeInteroperableAddress_longAddress() public view {
        bytes memory addressData = new bytes(100);
        for (uint256 i = 0; i < 100; i++) {
            addressData[i] = bytes1(uint8(i));
        }
        bytes memory data = abi.encodePacked(bytes4(0x12345678), abi.encode(addressData));

        bytes memory result = wrapper.decodeInteroperableAddress(data);

        assertEq(result, addressData);
    }

    function test_decodeInteroperableAddress_ignoresSelector() public view {
        bytes memory addressData = hex"cafe";

        bytes memory data1 = abi.encodePacked(bytes4(0x11111111), abi.encode(addressData));
        bytes memory data2 = abi.encodePacked(bytes4(0x22222222), abi.encode(addressData));

        assertEq(wrapper.decodeInteroperableAddress(data1), wrapper.decodeInteroperableAddress(data2));
    }

    // ============ Fuzz Tests ============

    function testFuzz_decodeUint256(bytes4 selector, uint256 value) public view {
        bytes memory data = abi.encodePacked(selector, abi.encode(value));

        uint256 result = wrapper.decodeUint256(data);

        assertEq(result, value);
    }

    function testFuzz_decodeInteroperableAddress(bytes4 selector, bytes memory addressData) public view {
        bytes memory data = abi.encodePacked(selector, abi.encode(addressData));

        bytes memory result = wrapper.decodeInteroperableAddress(data);

        assertEq(result, addressData);
    }
}
