// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropCallStarter, CallAttributes} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {AttributesDecoder} from "contracts/interop/AttributesDecoder.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";

import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

/// @title L2AssetRouterAttributesEncodingRegressionTestAbstract
/// @notice Regression tests for the callAttributes encoding fix in L2AssetRouter.initiateIndirectCall
abstract contract L2AssetRouterAttributesEncodingRegressionTestAbstract is Test, SharedL2ContractDeployer {
    uint256 destinationChainId = 271;

    function setUp() public virtual override {
        super.setUp();
    }

    /// @notice Test that abi.encodeCall produces the correct format for parseAttributes
    /// @dev This is a unit test verifying the encoding format difference
    function test_regression_abiEncodeCallVsAbiEncode() public pure {
        uint256 testValue = 12345;
        bytes4 selector = IERC7786Attributes.interopCallValue.selector;

        // CORRECT encoding using abi.encodeCall
        // Format: [4 bytes selector][32 bytes value] = 36 bytes
        bytes memory correctEncoding = abi.encodeCall(IERC7786Attributes.interopCallValue, testValue);

        // BUGGY encoding using abi.encode (the bug that was fixed)
        // Format: [4 bytes selector][28 bytes zero padding][32 bytes value] = 64 bytes
        // Note: abi.encode pads bytes4 to 32 bytes with right-padding (selector is left-aligned)
        bytes memory buggyEncoding = abi.encode(selector, testValue);

        // Verify the lengths are different
        assertEq(correctEncoding.length, 36, "Correct encoding should be 36 bytes (4 selector + 32 value)");
        assertEq(buggyEncoding.length, 64, "Buggy encoding should be 64 bytes (32 padded selector + 32 value)");

        // Verify the selector is at the start of both (bytes4 is left-aligned in abi.encode)
        bytes4 correctSelector = bytes4(correctEncoding);
        bytes4 buggySelector = bytes4(buggyEncoding);
        assertEq(correctSelector, selector, "Correct encoding should have selector at start");
        assertEq(buggySelector, selector, "Buggy encoding also has selector at start (left-aligned)");

        // The KEY difference: where the value is located
        // In correct encoding: value is at bytes[4:36]
        // In buggy encoding: bytes[4:36] contains 28 zeros + first 4 bytes of value
        // The actual value is at bytes[32:64] in buggy encoding

        // When AttributesDecoder reads _data[4:], it gets different data:
        // - Correct: [32 bytes value] -> decodes to testValue
        // - Buggy: [28 bytes zeros][first 4 bytes of value] -> decodes to wrong value
    }

    /// @notice Test that InteropCenter.parseAttributes correctly decodes the attributes from L2AssetRouter
    /// @dev This verifies the fix works end-to-end with parseAttributes
    function test_regression_parseAttributesDecodesCorrectly() public view {
        uint256 testValue = 1 ether;

        // Create attributes using the CORRECT encoding (as fixed in PR #1714)
        bytes[] memory attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, testValue);

        // Call parseAttributes to decode
        (CallAttributes memory callAttributes, ) = InteropCenter(L2_INTEROP_CENTER_ADDR).parseAttributes(
            attributes,
            IInteropCenter.AttributeParsingRestrictions.OnlyInteropCallValue
        );

        // Verify the value was decoded correctly
        assertEq(
            callAttributes.interopCallValue,
            testValue,
            "parseAttributes should decode the interopCallValue correctly"
        );
    }

    /// @notice Test that the buggy encoding would cause parseAttributes to return wrong value
    /// @dev This demonstrates the bug that was fixed
    function test_regression_buggyEncodingWouldReturnWrongValue() public view {
        uint256 testValue = 1 ether;
        bytes4 selector = IERC7786Attributes.interopCallValue.selector;

        // Create attributes using the BUGGY encoding (abi.encode instead of abi.encodeCall)
        bytes[] memory buggyAttributes = new bytes[](1);
        buggyAttributes[0] = abi.encode(selector, testValue);

        // Call parseAttributes to decode - this will return a wrong value
        (CallAttributes memory callAttributes, ) = InteropCenter(L2_INTEROP_CENTER_ADDR).parseAttributes(
            buggyAttributes,
            IInteropCenter.AttributeParsingRestrictions.OnlyInteropCallValue
        );

        // The decoded value should NOT equal the original value
        // because parseAttributes reads from _data[4:] which reads the padded selector bytes
        assertNotEq(
            callAttributes.interopCallValue,
            testValue,
            "Buggy encoding should NOT decode to the correct value"
        );
    }

    /// @notice Fuzz test for various values
    /// @dev Ensures the encoding works for any uint256 value
    function testFuzz_regression_attributesEncodingVariousValues(uint256 testValue) public view {
        // Create attributes using the correct encoding
        bytes[] memory attributes = new bytes[](1);
        attributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, testValue);

        // Verify parseAttributes decodes correctly
        (CallAttributes memory callAttributes, ) = InteropCenter(L2_INTEROP_CENTER_ADDR).parseAttributes(
            attributes,
            IInteropCenter.AttributeParsingRestrictions.OnlyInteropCallValue
        );

        assertEq(callAttributes.interopCallValue, testValue, "parseAttributes should decode any value correctly");
    }
}
