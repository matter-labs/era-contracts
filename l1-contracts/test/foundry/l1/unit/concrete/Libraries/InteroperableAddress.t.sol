// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";

/// @notice Helper contract to test InteroperableAddress library with calldata functions
contract InteroperableAddressHelper {
    function parseV1Calldata(
        bytes calldata data
    ) external pure returns (bytes2 chainType, bytes calldata chainReference, bytes calldata addr) {
        return InteroperableAddress.parseV1Calldata(data);
    }

    function tryParseV1Calldata(
        bytes calldata data
    ) external pure returns (bool success, bytes2 chainType, bytes calldata chainReference, bytes calldata addr) {
        return InteroperableAddress.tryParseV1Calldata(data);
    }

    function parseEvmV1Calldata(bytes calldata data) external pure returns (uint256 chainId, address addr) {
        return InteroperableAddress.parseEvmV1Calldata(data);
    }

    function tryParseEvmV1Calldata(
        bytes calldata data
    ) external pure returns (bool success, uint256 chainId, address addr) {
        return InteroperableAddress.tryParseEvmV1Calldata(data);
    }
}

/// @notice Unit tests for InteroperableAddress library
contract InteroperableAddressTest is Test {
    using InteroperableAddress for bytes;

    InteroperableAddressHelper internal helper;

    function setUp() public {
        helper = new InteroperableAddressHelper();
    }

    // ============ formatV1 Tests ============

    function test_formatV1_withChainReferenceAndAddress() public pure {
        bytes2 chainType = 0x0000;
        bytes memory chainReference = hex"01";
        bytes memory addr = hex"1234567890123456789012345678901234567890";

        bytes memory result = InteroperableAddress.formatV1(chainType, chainReference, addr);

        // Format: version(2) + chainType(2) + chainRefLen(1) + chainRef + addrLen(1) + addr
        assertEq(result.length, 2 + 2 + 1 + 1 + 1 + 20);
        assertEq(bytes2(bytes2(result[0]) | (bytes2(result[1]) >> 8)), bytes2(0x0001)); // version
    }

    function test_formatV1_withOnlyChainReference() public pure {
        bytes2 chainType = 0x0000;
        bytes memory chainReference = hex"01";
        bytes memory addr = "";

        bytes memory result = InteroperableAddress.formatV1(chainType, chainReference, addr);
        assertEq(result.length, 2 + 2 + 1 + 1 + 1 + 0);
    }

    function test_formatV1_withOnlyAddress() public pure {
        bytes2 chainType = 0x0000;
        bytes memory chainReference = "";
        bytes memory addr = hex"1234567890123456789012345678901234567890";

        bytes memory result = InteroperableAddress.formatV1(chainType, chainReference, addr);
        assertEq(result.length, 2 + 2 + 1 + 0 + 1 + 20);
    }

    function test_formatV1_revertsOnEmptyBoth() public {
        bytes2 chainType = 0x0000;
        bytes memory chainReference = "";
        bytes memory addr = "";

        vm.expectRevert(InteroperableAddress.InteroperableAddressEmptyReferenceAndAddress.selector);
        InteroperableAddress.formatV1(chainType, chainReference, addr);
    }

    // ============ formatEvmV1 Tests ============

    function test_formatEvmV1_withChainIdAndAddress() public pure {
        uint256 chainId = 1;
        address addr = address(0x1234567890123456789012345678901234567890);

        bytes memory result = InteroperableAddress.formatEvmV1(chainId, addr);

        // Should be valid EVM v1 format
        assertTrue(result.length > 0);
    }

    function test_formatEvmV1_withOnlyChainId() public pure {
        uint256 chainId = 1;

        bytes memory result = InteroperableAddress.formatEvmV1(chainId);
        assertTrue(result.length > 0);
    }

    function test_formatEvmV1_withOnlyAddress() public pure {
        address addr = address(0x1234567890123456789012345678901234567890);

        bytes memory result = InteroperableAddress.formatEvmV1(addr);

        // Should have fixed prefix and address
        assertEq(result.length, 6 + 20);
    }

    function test_formatEvmV1_largeChainId() public pure {
        uint256 chainId = type(uint128).max;
        address addr = address(0x1234567890123456789012345678901234567890);

        bytes memory result = InteroperableAddress.formatEvmV1(chainId, addr);
        assertTrue(result.length > 0);
    }

    // ============ parseV1 Tests ============

    function test_parseV1_validInput() public pure {
        // Format a valid address first
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), address(0x1234));

        (bytes2 chainType, bytes memory chainReference, bytes memory addr) = formatted.parseV1();

        assertEq(chainType, bytes2(0x0000)); // EVM chain type
    }

    function test_parseV1_revertsOnInvalidVersion() public {
        // Create invalid version (0x0002 instead of 0x0001)
        bytes memory invalidInput = hex"00020000011400001234567890123456789012345678901234567890";

        vm.expectRevert(
            abi.encodeWithSelector(InteroperableAddress.InteroperableAddressParsingError.selector, invalidInput)
        );
        invalidInput.parseV1();
    }

    function test_parseV1_revertsOnTooShort() public {
        bytes memory tooShort = hex"0001";

        vm.expectRevert(
            abi.encodeWithSelector(InteroperableAddress.InteroperableAddressParsingError.selector, tooShort)
        );
        tooShort.parseV1();
    }

    // ============ tryParseV1 Tests ============

    function test_tryParseV1_validInput() public pure {
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), address(0x1234));

        (bool success, bytes2 chainType, bytes memory chainReference, bytes memory addr) = formatted.tryParseV1();

        assertTrue(success);
        assertEq(chainType, bytes2(0x0000));
    }

    function test_tryParseV1_invalidVersion() public pure {
        bytes memory invalidInput = hex"00020000011400001234567890123456789012345678901234567890";

        (bool success, , , ) = invalidInput.tryParseV1();
        assertFalse(success);
    }

    function test_tryParseV1_tooShort() public pure {
        bytes memory tooShort = hex"0001";

        (bool success, , , ) = tooShort.tryParseV1();
        assertFalse(success);
    }

    function test_tryParseV1_chainReferenceTooLong() public pure {
        // Version + chainType + chainRefLen(255) but no actual data
        bytes memory invalid = hex"000100001400";

        (bool success, , , ) = invalid.tryParseV1();
        assertFalse(success);
    }

    // ============ parseV1Calldata Tests ============

    function test_parseV1Calldata_validInput() public view {
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), address(0x1234));

        (bytes2 chainType, bytes memory chainReference, bytes memory addr) = helper.parseV1Calldata(formatted);

        assertEq(chainType, bytes2(0x0000));
    }

    function test_parseV1Calldata_revertsOnInvalid() public {
        bytes memory invalidInput = hex"00020000011400001234567890123456789012345678901234567890";

        vm.expectRevert(
            abi.encodeWithSelector(InteroperableAddress.InteroperableAddressParsingError.selector, invalidInput)
        );
        helper.parseV1Calldata(invalidInput);
    }

    // ============ tryParseV1Calldata Tests ============

    function test_tryParseV1Calldata_validInput() public view {
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), address(0x1234));

        (bool success, bytes2 chainType, , ) = helper.tryParseV1Calldata(formatted);

        assertTrue(success);
        assertEq(chainType, bytes2(0x0000));
    }

    function test_tryParseV1Calldata_invalidVersion() public view {
        bytes memory invalidInput = hex"00020000011400001234567890123456789012345678901234567890";

        (bool success, , , ) = helper.tryParseV1Calldata(invalidInput);
        assertFalse(success);
    }

    function test_tryParseV1Calldata_tooShort() public view {
        bytes memory tooShort = hex"0001";

        (bool success, , , ) = helper.tryParseV1Calldata(tooShort);
        assertFalse(success);
    }

    // ============ parseEvmV1 Tests ============

    function test_parseEvmV1_validInput() public pure {
        address expectedAddr = address(0x1234567890123456789012345678901234567890);
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), expectedAddr);

        (uint256 chainId, address addr) = formatted.parseEvmV1();

        assertEq(chainId, 1);
        assertEq(addr, expectedAddr);
    }

    function test_parseEvmV1_withoutAddress() public pure {
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(42));

        (uint256 chainId, address addr) = formatted.parseEvmV1();

        assertEq(chainId, 42);
        assertEq(addr, address(0));
    }

    function test_parseEvmV1_revertsOnNonEvmChainType() public {
        // Create non-EVM chain type (0x0001 instead of 0x0000)
        bytes memory nonEvm = hex"000100010114001234567890123456789012345678901234567890";

        vm.expectRevert(abi.encodeWithSelector(InteroperableAddress.InteroperableAddressParsingError.selector, nonEvm));
        nonEvm.parseEvmV1();
    }

    // ============ tryParseEvmV1 Tests ============

    function test_tryParseEvmV1_validInput() public pure {
        address expectedAddr = address(0x1234567890123456789012345678901234567890);
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), expectedAddr);

        (bool success, uint256 chainId, address addr) = formatted.tryParseEvmV1();

        assertTrue(success);
        assertEq(chainId, 1);
        assertEq(addr, expectedAddr);
    }

    function test_tryParseEvmV1_nonEvmChainType() public pure {
        bytes memory nonEvm = hex"000100010114001234567890123456789012345678901234567890";

        (bool success, , ) = nonEvm.tryParseEvmV1();
        assertFalse(success);
    }

    function test_tryParseEvmV1_invalidAddressLength() public pure {
        // Create with address length != 0 and != 20
        // Format: version(0001) + chainType(0000) + chainRefLen(01) + chainRef(01) + addrLen(0a=10) + 10 bytes addr
        bytes memory invalid = hex"0001000001010a12345678901234567890";

        (bool success, , ) = invalid.tryParseEvmV1();
        assertFalse(success);
    }

    function test_tryParseEvmV1_chainReferenceTooLong() public pure {
        // Chain reference > 32 bytes (version + chainType + chainRefLen=33 + 33 bytes chainRef + addrLen + 20 bytes addr)
        bytes memory invalid = hex"0001000021"
        hex"0102030405060708091011121314151617181920212223242526272829303132330014"
        hex"1234567890123456789012345678901234567890";

        (bool success, , ) = invalid.tryParseEvmV1();
        assertFalse(success);
    }

    // ============ parseEvmV1Calldata Tests ============

    function test_parseEvmV1Calldata_validInput() public view {
        address expectedAddr = address(0x1234567890123456789012345678901234567890);
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), expectedAddr);

        (uint256 chainId, address addr) = helper.parseEvmV1Calldata(formatted);

        assertEq(chainId, 1);
        assertEq(addr, expectedAddr);
    }

    // ============ tryParseEvmV1Calldata Tests ============

    function test_tryParseEvmV1Calldata_validInput() public view {
        address expectedAddr = address(0x1234567890123456789012345678901234567890);
        bytes memory formatted = InteroperableAddress.formatEvmV1(uint256(1), expectedAddr);

        (bool success, uint256 chainId, address addr) = helper.tryParseEvmV1Calldata(formatted);

        assertTrue(success);
        assertEq(chainId, 1);
        assertEq(addr, expectedAddr);
    }

    function test_tryParseEvmV1Calldata_invalidInput() public view {
        bytes memory invalid = hex"0002"; // wrong version

        (bool success, , ) = helper.tryParseEvmV1Calldata(invalid);
        assertFalse(success);
    }

    // ============ Roundtrip Tests ============

    function test_roundtrip_formatAndParseEvmV1() public pure {
        uint256 originalChainId = 137;
        address originalAddr = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);

        bytes memory formatted = InteroperableAddress.formatEvmV1(originalChainId, originalAddr);
        (uint256 parsedChainId, address parsedAddr) = formatted.parseEvmV1();

        assertEq(parsedChainId, originalChainId);
        assertEq(parsedAddr, originalAddr);
    }

    function test_roundtrip_formatAndParseEvmV1_onlyChainId() public pure {
        uint256 originalChainId = 42161;

        bytes memory formatted = InteroperableAddress.formatEvmV1(originalChainId);
        (uint256 parsedChainId, address parsedAddr) = formatted.parseEvmV1();

        assertEq(parsedChainId, originalChainId);
        assertEq(parsedAddr, address(0));
    }

    function test_roundtrip_formatAndParseEvmV1_onlyAddress() public pure {
        address originalAddr = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);

        bytes memory formatted = InteroperableAddress.formatEvmV1(originalAddr);
        (uint256 parsedChainId, address parsedAddr) = formatted.parseEvmV1();

        assertEq(parsedChainId, 0);
        assertEq(parsedAddr, originalAddr);
    }

    // ============ Fuzz Tests ============

    function testFuzz_roundtrip_formatAndParseEvmV1(uint256 chainId, address addr) public pure {
        vm.assume(chainId > 0); // chainId 0 produces empty chain reference
        bytes memory formatted = InteroperableAddress.formatEvmV1(chainId, addr);
        (uint256 parsedChainId, address parsedAddr) = formatted.parseEvmV1();

        assertEq(parsedChainId, chainId);
        assertEq(parsedAddr, addr);
    }
}
