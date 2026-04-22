// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {StrictInteroperableAddressesParser} from "contracts/interop/StrictInteroperableAddressesParser.sol";

/// @notice Helper contract to exercise the calldata-taking functions of
/// {StrictInteroperableAddressesParser} via an external call so that `bytes memory`
/// inputs from the test can be passed as `bytes calldata`.
contract StrictInteroperableAddressesParserHelper {
    function parseV1Calldata(
        bytes calldata data
    ) external pure returns (bytes2 chainType, bytes calldata chainReference, bytes calldata addr) {
        return StrictInteroperableAddressesParser.parseV1Calldata(data);
    }

    function tryParseV1Calldata(
        bytes calldata data
    ) external pure returns (bool success, bytes2 chainType, bytes calldata chainReference, bytes calldata addr) {
        return StrictInteroperableAddressesParser.tryParseV1Calldata(data);
    }

    function parseEvmV1Calldata(bytes calldata data) external pure returns (uint256 chainId, address addr) {
        return StrictInteroperableAddressesParser.parseEvmV1Calldata(data);
    }

    function tryParseEvmV1Calldata(
        bytes calldata data
    ) external pure returns (bool success, uint256 chainId, address addr) {
        return StrictInteroperableAddressesParser.tryParseEvmV1Calldata(data);
    }
}

/// @notice Unit tests for the strict wrappers in {StrictInteroperableAddressesParser}.
/// The strict wrappers forward to the vendor parser once they have confirmed that the
/// payload length matches the declared layout exactly. The tests below therefore focus
/// on:
/// 1. Valid inputs still parsing identically to the vendor parser.
/// 2. Trailing bytes beyond the declared layout being rejected (vendor accepts them).
/// 3. Truncated inputs (shorter than the declared layout) being rejected, just like
///    the vendor parser does.
contract StrictInteroperableAddressesParserTest is Test {
    StrictInteroperableAddressesParserHelper internal helper;

    function setUp() public {
        helper = new StrictInteroperableAddressesParserHelper();
    }

    // ============ parseV1Calldata ============

    function test_parseV1Calldata_validInput() public view {
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), address(0x1234));

        (bytes2 chainType, , ) = helper.parseV1Calldata(formatted);
        assertEq(chainType, bytes2(0x0000));
    }

    function test_parseV1Calldata_revertsOnTrailingBytes() public {
        bytes memory formattedWithTrailingByte = bytes.concat(
            InteroperableAddress.formatEvmV1(uint256(1), address(0x1234)),
            hex"00"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                InteroperableAddress.InteroperableAddressParsingError.selector,
                formattedWithTrailingByte
            )
        );
        helper.parseV1Calldata(formattedWithTrailingByte);
    }

    function test_parseV1Calldata_revertsOnTooShortForMinimum() public {
        bytes memory tooShort = hex"0001";

        vm.expectRevert(
            abi.encodeWithSelector(InteroperableAddress.InteroperableAddressParsingError.selector, tooShort)
        );
        helper.parseV1Calldata(tooShort);
    }

    function test_parseV1Calldata_revertsOnMissingAddressLengthByte() public {
        // 5 bytes: enough to read chainReferenceLength (at index 4) but not addressLength (at
        // index 5 + chainReferenceLength). The strict parser must reject because
        // self.length < ERC7930_V1_MIN_LENGTH.
        bytes memory tooShort = hex"0001000000";

        vm.expectRevert(
            abi.encodeWithSelector(InteroperableAddress.InteroperableAddressParsingError.selector, tooShort)
        );
        helper.parseV1Calldata(tooShort);
    }

    function test_parseV1Calldata_revertsOnTruncatedChainReference() public {
        // Declared chainReferenceLength = 3 but only 1 byte of chainReference data present
        // after the header; total length (7) is shorter than 6 + 3 = 9.
        bytes memory truncated = hex"00010000030100";

        vm.expectRevert(
            abi.encodeWithSelector(InteroperableAddress.InteroperableAddressParsingError.selector, truncated)
        );
        helper.parseV1Calldata(truncated);
    }

    // ============ tryParseV1Calldata ============

    function test_tryParseV1Calldata_validInput() public view {
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), address(0x1234));

        (bool success, bytes2 chainType, , ) = helper.tryParseV1Calldata(formatted);
        assertTrue(success);
        assertEq(chainType, bytes2(0x0000));
    }

    function test_tryParseV1Calldata_failsOnTrailingBytes() public view {
        bytes memory formattedWithTrailingByte = bytes.concat(
            InteroperableAddress.formatEvmV1(uint256(1), address(0x1234)),
            hex"00"
        );

        (bool success, , , ) = helper.tryParseV1Calldata(formattedWithTrailingByte);
        assertFalse(success);
    }

    function test_tryParseV1Calldata_failsOnMissingAddressLengthByte() public view {
        bytes memory tooShort = hex"0001000000";

        (bool success, , , ) = helper.tryParseV1Calldata(tooShort);
        assertFalse(success);
    }

    function test_tryParseV1Calldata_failsOnTruncatedChainReference() public view {
        bytes memory truncated = hex"00010000030100";

        (bool success, , , ) = helper.tryParseV1Calldata(truncated);
        assertFalse(success);
    }

    // ============ parseEvmV1Calldata ============

    function test_parseEvmV1Calldata_validInput() public view {
        address expectedAddr = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(137), expectedAddr);

        (uint256 chainId, address addr) = helper.parseEvmV1Calldata(formatted);
        assertEq(chainId, 137);
        assertEq(addr, expectedAddr);
    }

    function test_parseEvmV1Calldata_revertsOnTrailingBytes() public {
        bytes memory formattedWithTrailingByte = bytes.concat(
            InteroperableAddress.formatEvmV1(uint256(1), address(0x1234)),
            hex"abcd"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                InteroperableAddress.InteroperableAddressParsingError.selector,
                formattedWithTrailingByte
            )
        );
        helper.parseEvmV1Calldata(formattedWithTrailingByte);
    }

    // ============ parseEvmV1 (memory) ============

    function test_parseEvmV1_memory_validInput() public pure {
        address expectedAddr = address(0x1234567890123456789012345678901234567890);
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), expectedAddr);

        (uint256 chainId, address addr) = StrictInteroperableAddressesParser.parseEvmV1(formatted);
        assertEq(chainId, 1);
        assertEq(addr, expectedAddr);
    }

    function test_parseEvmV1_memory_revertsOnTrailingBytes() public {
        bytes memory formattedWithTrailingByte = bytes.concat(
            InteroperableAddress.formatEvmV1(uint256(1), address(0x1234)),
            hex"ff"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                InteroperableAddress.InteroperableAddressParsingError.selector,
                formattedWithTrailingByte
            )
        );
        StrictInteroperableAddressesParser.parseEvmV1(formattedWithTrailingByte);
    }

    // ============ tryParseEvmV1Calldata ============

    function test_tryParseEvmV1Calldata_validInput() public view {
        address expectedAddr = address(0x1234567890123456789012345678901234567890);
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), expectedAddr);

        (bool success, uint256 chainId, address addr) = helper.tryParseEvmV1Calldata(formatted);
        assertTrue(success);
        assertEq(chainId, 1);
        assertEq(addr, expectedAddr);
    }

    function test_tryParseEvmV1Calldata_failsOnTrailingBytes() public view {
        bytes memory formattedWithTrailingByte = bytes.concat(
            InteroperableAddress.formatEvmV1(uint256(1), address(0x1234)),
            hex"00"
        );

        (bool success, , ) = helper.tryParseEvmV1Calldata(formattedWithTrailingByte);
        assertFalse(success);
    }

    function test_tryParseEvmV1Calldata_failsOnInvalidChainType() public view {
        // Non-EVM chainType (0x0001 instead of 0x0000), length matches strictly.
        // Strict length check passes, but vendor tryParseEvmV1Calldata rejects the chainType.
        bytes memory nonEvm = hex"000100010114001234567890123456789012345678901234567890";

        (bool success, , ) = helper.tryParseEvmV1Calldata(nonEvm);
        assertFalse(success);
    }

    // ============ Fuzz ============

    function testFuzz_parseEvmV1Calldata_roundtrip(uint256 chainId, address addr) public view {
        vm.assume(chainId > 0);
        bytes memory formatted = InteroperableAddress.formatEvmV1(chainId, addr);

        (uint256 parsedChainId, address parsedAddr) = helper.parseEvmV1Calldata(formatted);
        assertEq(parsedChainId, chainId);
        assertEq(parsedAddr, addr);
    }

    function testFuzz_parseEvmV1Calldata_trailingBytesAlwaysRevert(
        uint256 chainId,
        address addr,
        bytes calldata tail
    ) public {
        vm.assume(chainId > 0);
        vm.assume(tail.length > 0);
        bytes memory formatted = bytes.concat(InteroperableAddress.formatEvmV1(chainId, addr), tail);

        vm.expectRevert(
            abi.encodeWithSelector(InteroperableAddress.InteroperableAddressParsingError.selector, formatted)
        );
        helper.parseEvmV1Calldata(formatted);
    }
}
