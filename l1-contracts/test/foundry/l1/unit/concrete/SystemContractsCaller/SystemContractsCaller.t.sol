// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {
    CalldataForwardingMode,
    SystemContractsCaller,
    U32CastOverflow,
    Utils
} from "contracts/common/l2-helpers/SystemContractsCaller.sol";

contract SystemContractsCallerTest is Test {
    using SystemContractsCaller for *;

    address public constant TEST_TARGET = address(0x123);
    uint32 public constant TEST_GAS_LIMIT = 100000;
    uint256 public constant TEST_VALUE = 1 ether;
    uint128 public constant TEST_VALUE_128 = 1 ether;
    bytes public constant TEST_DATA = "test data";

    function setUp() public {}

    function test_Utils_SafeCastToU32_Success() public {
        uint256 value = 1000;
        uint32 result = Utils.safeCastToU32(value);
        assertEq(result, 1000);
    }

    function test_Utils_SafeCastToU32_MaxValue() public {
        uint256 value = type(uint32).max;
        uint32 result = Utils.safeCastToU32(value);
        assertEq(result, type(uint32).max);
    }

    function test_Utils_SafeCastToU32_Overflow() public {
        uint256 value = uint256(type(uint32).max) + 1;
        vm.expectRevert(U32CastOverflow.selector);
        Utils.safeCastToU32(value);
    }

    function test_GetFarCallABIWithEmptyFatPointer() public {
        uint32 gasPassed = 50000;
        uint8 shardId = 1;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseHeap;
        bool isConstructorCall = false;
        bool isSystemCall = true;

        uint256 result = SystemContractsCaller.getFarCallABIWithEmptyFatPointer(
            gasPassed,
            shardId,
            forwardingMode,
            isConstructorCall,
            isSystemCall
        );

        // Check that the bits are set correctly
        assertEq(result & 0xFFFFFFFF, 0); // dataOffset
        assertEq((result >> 32) & 0xFFFFFFFF, 0); // memoryPage
        assertEq((result >> 64) & 0xFFFFFFFF, 0); // dataStart
        assertEq((result >> 96) & 0xFFFFFFFF, 0); // dataLength
        assertEq((result >> 192) & 0xFFFFFFFF, gasPassed); // gasPassed
        assertEq((result >> 224) & 0xFF, uint256(forwardingMode)); // forwardingMode
        assertEq((result >> 232) & 0xFF, shardId); // shardId
        assertEq((result >> 240) & 0x1, isConstructorCall ? 1 : 0); // isConstructorCall
        assertEq((result >> 248) & 0x1, isSystemCall ? 1 : 0); // isSystemCall
    }

    function test_GetFarCallABIWithEmptyFatPointer_ConstructorCall() public {
        uint32 gasPassed = 50000;
        uint8 shardId = 1;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseHeap;
        bool isConstructorCall = true;
        bool isSystemCall = true;

        uint256 result = SystemContractsCaller.getFarCallABIWithEmptyFatPointer(
            gasPassed,
            shardId,
            forwardingMode,
            isConstructorCall,
            isSystemCall
        );

        assertEq((result >> 240) & 0x1, 1); // isConstructorCall should be 1
        assertEq((result >> 248) & 0x1, 1); // isSystemCall should be 1
    }

    function test_GetFarCallABIWithEmptyFatPointer_NotSystemCall() public {
        uint32 gasPassed = 50000;
        uint8 shardId = 1;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseHeap;
        bool isConstructorCall = false;
        bool isSystemCall = false;

        uint256 result = SystemContractsCaller.getFarCallABIWithEmptyFatPointer(
            gasPassed,
            shardId,
            forwardingMode,
            isConstructorCall,
            isSystemCall
        );

        assertEq((result >> 240) & 0x1, 0); // isConstructorCall should be 0
        assertEq((result >> 248) & 0x1, 0); // isSystemCall should be 0
    }

    function test_GetFarCallABIWithEmptyFatPointer_AllForwardingModes() public {
        uint32 gasPassed = 50000;
        uint8 shardId = 1;
        bool isConstructorCall = false;
        bool isSystemCall = true;

        // Test UseHeap
        uint256 result1 = SystemContractsCaller.getFarCallABIWithEmptyFatPointer(
            gasPassed,
            shardId,
            CalldataForwardingMode.UseHeap,
            isConstructorCall,
            isSystemCall
        );
        assertEq((result1 >> 224) & 0xFF, uint256(CalldataForwardingMode.UseHeap));

        // Test ForwardFatPointer
        uint256 result2 = SystemContractsCaller.getFarCallABIWithEmptyFatPointer(
            gasPassed,
            shardId,
            CalldataForwardingMode.ForwardFatPointer,
            isConstructorCall,
            isSystemCall
        );
        assertEq((result2 >> 224) & 0xFF, uint256(CalldataForwardingMode.ForwardFatPointer));

        // Test UseAuxHeap
        uint256 result3 = SystemContractsCaller.getFarCallABIWithEmptyFatPointer(
            gasPassed,
            shardId,
            CalldataForwardingMode.UseAuxHeap,
            isConstructorCall,
            isSystemCall
        );
        assertEq((result3 >> 224) & 0xFF, uint256(CalldataForwardingMode.UseAuxHeap));
    }

    function test_GetFarCallABI() public {
        uint32 dataOffset = 0;
        uint32 memoryPage = 0;
        uint32 dataStart = 0x20;
        uint32 dataLength = 100;
        uint32 gasPassed = 50000;
        uint8 shardId = 1;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseHeap;
        bool isConstructorCall = false;
        bool isSystemCall = true;

        uint256 result = SystemContractsCaller.getFarCallABI(
            dataOffset,
            memoryPage,
            dataStart,
            dataLength,
            gasPassed,
            shardId,
            forwardingMode,
            isConstructorCall,
            isSystemCall
        );

        // Check that all fields are set correctly
        assertEq(result & 0xFFFFFFFF, dataOffset); // dataOffset
        assertEq((result >> 32) & 0xFFFFFFFF, memoryPage); // memoryPage
        assertEq((result >> 64) & 0xFFFFFFFF, dataStart); // dataStart
        assertEq((result >> 96) & 0xFFFFFFFF, dataLength); // dataLength
        assertEq((result >> 192) & 0xFFFFFFFF, gasPassed); // gasPassed
        assertEq((result >> 224) & 0xFF, uint256(forwardingMode)); // forwardingMode
        assertEq((result >> 232) & 0xFF, shardId); // shardId
        assertEq((result >> 240) & 0x1, isConstructorCall ? 1 : 0); // isConstructorCall
        assertEq((result >> 248) & 0x1, isSystemCall ? 1 : 0); // isSystemCall
    }

    function test_GetFarCallABI_MaxValues() public {
        uint32 dataOffset = type(uint32).max;
        uint32 memoryPage = type(uint32).max;
        uint32 dataStart = type(uint32).max;
        uint32 dataLength = type(uint32).max;
        uint32 gasPassed = type(uint32).max;
        uint8 shardId = type(uint8).max;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseAuxHeap;
        bool isConstructorCall = true;
        bool isSystemCall = true;

        uint256 result = SystemContractsCaller.getFarCallABI(
            dataOffset,
            memoryPage,
            dataStart,
            dataLength,
            gasPassed,
            shardId,
            forwardingMode,
            isConstructorCall,
            isSystemCall
        );

        // Check that all fields are set correctly
        assertEq(result & 0xFFFFFFFF, dataOffset);
        assertEq((result >> 32) & 0xFFFFFFFF, memoryPage);
        assertEq((result >> 64) & 0xFFFFFFFF, dataStart);
        assertEq((result >> 96) & 0xFFFFFFFF, dataLength);
        assertEq((result >> 192) & 0xFFFFFFFF, gasPassed);
        assertEq((result >> 224) & 0xFF, uint256(forwardingMode));
        assertEq((result >> 232) & 0xFF, shardId);
        assertEq((result >> 240) & 0x1, 1);
        assertEq((result >> 248) & 0x1, 1);
    }

    function test_GetFarCallABI_ZeroValues() public {
        uint32 dataOffset = 0;
        uint32 memoryPage = 0;
        uint32 dataStart = 0;
        uint32 dataLength = 0;
        uint32 gasPassed = 0;
        uint8 shardId = 0;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseHeap;
        bool isConstructorCall = false;
        bool isSystemCall = false;

        uint256 result = SystemContractsCaller.getFarCallABI(
            dataOffset,
            memoryPage,
            dataStart,
            dataLength,
            gasPassed,
            shardId,
            forwardingMode,
            isConstructorCall,
            isSystemCall
        );

        // Check that all fields are set correctly
        assertEq(result & 0xFFFFFFFF, dataOffset);
        assertEq((result >> 32) & 0xFFFFFFFF, memoryPage);
        assertEq((result >> 64) & 0xFFFFFFFF, dataStart);
        assertEq((result >> 96) & 0xFFFFFFFF, dataLength);
        assertEq((result >> 192) & 0xFFFFFFFF, gasPassed);
        assertEq((result >> 224) & 0xFF, uint256(forwardingMode));
        assertEq((result >> 232) & 0xFF, shardId);
        assertEq((result >> 240) & 0x1, 0);
        assertEq((result >> 248) & 0x1, 0);
    }

    function test_GetFarCallABI_DifferentShardIds() public {
        uint32 dataOffset = 0;
        uint32 memoryPage = 0;
        uint32 dataStart = 0x20;
        uint32 dataLength = 100;
        uint32 gasPassed = 50000;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseHeap;
        bool isConstructorCall = false;
        bool isSystemCall = true;

        for (uint8 shardId = 0; shardId < 10; shardId++) {
            uint256 result = SystemContractsCaller.getFarCallABI(
                dataOffset,
                memoryPage,
                dataStart,
                dataLength,
                gasPassed,
                shardId,
                forwardingMode,
                isConstructorCall,
                isSystemCall
            );

            assertEq((result >> 232) & 0xFF, shardId);
        }
    }

    function test_GetFarCallABI_DifferentDataOffsets() public {
        uint32 memoryPage = 0;
        uint32 dataStart = 0x20;
        uint32 dataLength = 100;
        uint32 gasPassed = 50000;
        uint8 shardId = 1;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseHeap;
        bool isConstructorCall = false;
        bool isSystemCall = true;

        for (uint32 dataOffset = 0; dataOffset < 10; dataOffset++) {
            uint256 result = SystemContractsCaller.getFarCallABI(
                dataOffset,
                memoryPage,
                dataStart,
                dataLength,
                gasPassed,
                shardId,
                forwardingMode,
                isConstructorCall,
                isSystemCall
            );

            assertEq(result & 0xFFFFFFFF, dataOffset);
        }
    }

    function test_GetFarCallABI_DifferentDataLengths() public {
        uint32 dataOffset = 0;
        uint32 memoryPage = 0;
        uint32 dataStart = 0x20;
        uint32 gasPassed = 50000;
        uint8 shardId = 1;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseHeap;
        bool isConstructorCall = false;
        bool isSystemCall = true;

        for (uint32 dataLength = 0; dataLength < 10; dataLength++) {
            uint256 result = SystemContractsCaller.getFarCallABI(
                dataOffset,
                memoryPage,
                dataStart,
                dataLength,
                gasPassed,
                shardId,
                forwardingMode,
                isConstructorCall,
                isSystemCall
            );

            assertEq((result >> 96) & 0xFFFFFFFF, dataLength);
        }
    }

    function test_GetFarCallABI_DifferentGasPassed() public {
        uint32 dataOffset = 0;
        uint32 memoryPage = 0;
        uint32 dataStart = 0x20;
        uint32 dataLength = 100;
        uint8 shardId = 1;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseHeap;
        bool isConstructorCall = false;
        bool isSystemCall = true;

        for (uint32 gasPassed = 0; gasPassed < 10; gasPassed++) {
            uint256 result = SystemContractsCaller.getFarCallABI(
                dataOffset,
                memoryPage,
                dataStart,
                dataLength,
                gasPassed,
                shardId,
                forwardingMode,
                isConstructorCall,
                isSystemCall
            );

            assertEq((result >> 192) & 0xFFFFFFFF, gasPassed);
        }
    }

    function test_GetFarCallABI_AllForwardingModes() public {
        uint32 dataOffset = 0;
        uint32 memoryPage = 0;
        uint32 dataStart = 0x20;
        uint32 dataLength = 100;
        uint32 gasPassed = 50000;
        uint8 shardId = 1;
        bool isConstructorCall = false;
        bool isSystemCall = true;

        // Test UseHeap
        uint256 result1 = SystemContractsCaller.getFarCallABI(
            dataOffset,
            memoryPage,
            dataStart,
            dataLength,
            gasPassed,
            shardId,
            CalldataForwardingMode.UseHeap,
            isConstructorCall,
            isSystemCall
        );
        assertEq((result1 >> 224) & 0xFF, uint256(CalldataForwardingMode.UseHeap));

        // Test ForwardFatPointer
        uint256 result2 = SystemContractsCaller.getFarCallABI(
            dataOffset,
            memoryPage,
            dataStart,
            dataLength,
            gasPassed,
            shardId,
            CalldataForwardingMode.ForwardFatPointer,
            isConstructorCall,
            isSystemCall
        );
        assertEq((result2 >> 224) & 0xFF, uint256(CalldataForwardingMode.ForwardFatPointer));

        // Test UseAuxHeap
        uint256 result3 = SystemContractsCaller.getFarCallABI(
            dataOffset,
            memoryPage,
            dataStart,
            dataLength,
            gasPassed,
            shardId,
            CalldataForwardingMode.UseAuxHeap,
            isConstructorCall,
            isSystemCall
        );
        assertEq((result3 >> 224) & 0xFF, uint256(CalldataForwardingMode.UseAuxHeap));
    }

    function test_GetFarCallABI_AllCombinations() public {
        uint32 dataOffset = 0;
        uint32 memoryPage = 0;
        uint32 dataStart = 0x20;
        uint32 dataLength = 100;
        uint32 gasPassed = 50000;
        uint8 shardId = 1;

        // Test all combinations of boolean flags
        for (uint i = 0; i < 4; i++) {
            bool isConstructorCall = (i & 1) == 1;
            bool isSystemCall = (i & 2) == 2;

            uint256 result = SystemContractsCaller.getFarCallABI(
                dataOffset,
                memoryPage,
                dataStart,
                dataLength,
                gasPassed,
                shardId,
                CalldataForwardingMode.UseHeap,
                isConstructorCall,
                isSystemCall
            );

            assertEq((result >> 240) & 0x1, isConstructorCall ? 1 : 0);
            assertEq((result >> 248) & 0x1, isSystemCall ? 1 : 0);
        }
    }

    function test_GetFarCallABI_EdgeCases() public {
        uint32 dataOffset = 1;
        uint32 memoryPage = 1;
        uint32 dataStart = 0x21;
        uint32 dataLength = 1;
        uint32 gasPassed = 1;
        uint8 shardId = 1;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseHeap;
        bool isConstructorCall = true;
        bool isSystemCall = true;

        uint256 result = SystemContractsCaller.getFarCallABI(
            dataOffset,
            memoryPage,
            dataStart,
            dataLength,
            gasPassed,
            shardId,
            forwardingMode,
            isConstructorCall,
            isSystemCall
        );

        // Check that all fields are set correctly
        assertEq(result & 0xFFFFFFFF, dataOffset);
        assertEq((result >> 32) & 0xFFFFFFFF, memoryPage);
        assertEq((result >> 64) & 0xFFFFFFFF, dataStart);
        assertEq((result >> 96) & 0xFFFFFFFF, dataLength);
        assertEq((result >> 192) & 0xFFFFFFFF, gasPassed);
        assertEq((result >> 224) & 0xFF, uint256(forwardingMode));
        assertEq((result >> 232) & 0xFF, shardId);
        assertEq((result >> 240) & 0x1, 1);
        assertEq((result >> 248) & 0x1, 1);
    }

    function test_GetFarCallABI_BitManipulation() public {
        uint32 dataOffset = 0x12345678;
        uint32 memoryPage = 0x87654321;
        uint32 dataStart = 0x11111111;
        uint32 dataLength = 0x22222222;
        uint32 gasPassed = 0x33333333;
        uint8 shardId = 0x44;
        CalldataForwardingMode forwardingMode = CalldataForwardingMode.UseAuxHeap;
        bool isConstructorCall = true;
        bool isSystemCall = true;

        uint256 result = SystemContractsCaller.getFarCallABI(
            dataOffset,
            memoryPage,
            dataStart,
            dataLength,
            gasPassed,
            shardId,
            forwardingMode,
            isConstructorCall,
            isSystemCall
        );

        // Check that all fields are set correctly with bit manipulation
        assertEq(result & 0xFFFFFFFF, dataOffset);
        assertEq((result >> 32) & 0xFFFFFFFF, memoryPage);
        assertEq((result >> 64) & 0xFFFFFFFF, dataStart);
        assertEq((result >> 96) & 0xFFFFFFFF, dataLength);
        assertEq((result >> 192) & 0xFFFFFFFF, gasPassed);
        assertEq((result >> 224) & 0xFF, uint256(forwardingMode));
        assertEq((result >> 232) & 0xFF, shardId);
        assertEq((result >> 240) & 0x1, 1);
        assertEq((result >> 248) & 0x1, 1);
    }
}
