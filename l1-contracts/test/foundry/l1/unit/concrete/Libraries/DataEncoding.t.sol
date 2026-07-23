// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR, L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    InvalidNTVBurnData,
    UnsupportedEncodingVersion,
    BadTransferDataLength
} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for DataEncoding library
contract DataEncodingTest is Test {
    // ============ encodeBridgeBurnData / decodeBridgeBurnData Tests ============

    function test_encodeBridgeBurnData_basicValues() public pure {
        uint256 amount = 1000;
        address receiver = address(0x1234);
        address tokenAddress = address(0x5678);

        bytes memory encoded = DataEncoding.encodeBridgeBurnData(amount, receiver, tokenAddress);

        (uint256 decodedAmount, address decodedReceiver, address decodedToken) = DataEncoding.decodeBridgeBurnData(
            encoded
        );

        assertEq(decodedAmount, amount);
        assertEq(decodedReceiver, receiver);
        assertEq(decodedToken, tokenAddress);
    }

    function test_decodeBridgeBurnData_revertsOnInvalidLength() public {
        bytes memory invalidData = hex"1234"; // Too short

        vm.expectRevert(InvalidNTVBurnData.selector);
        DataEncoding.decodeBridgeBurnData(invalidData);
    }

    function testFuzz_roundtrip_bridgeBurnData(uint256 amount, address receiver, address tokenAddress) public pure {
        bytes memory encoded = DataEncoding.encodeBridgeBurnData(amount, receiver, tokenAddress);
        (uint256 decodedAmount, address decodedReceiver, address decodedToken) = DataEncoding.decodeBridgeBurnData(
            encoded
        );

        assertEq(decodedAmount, amount);
        assertEq(decodedReceiver, receiver);
        assertEq(decodedToken, tokenAddress);
    }

    // ============ encodeAssetRouterBridgehubDepositData / decodeAssetRouterBridgehubDepositData Tests ============

    function test_encodeAssetRouterBridgehubDepositData_basicValues() public pure {
        bytes32 assetId = bytes32(uint256(0x12345));
        bytes memory transferData = hex"abcdef";

        bytes memory encoded = DataEncoding.encodeAssetRouterBridgehubDepositData(assetId, transferData);

        // Should start with NEW_ENCODING_VERSION
        assertEq(encoded[0], NEW_ENCODING_VERSION);
    }

    function test_decodeAssetRouterBridgehubDepositData_revertsOnShortData() public {
        bytes memory shortData = hex"0100"; // Too short (less than 33 bytes)

        vm.expectRevert(BadTransferDataLength.selector);
        this.externalDecodeAssetRouterBridgehubDepositData(shortData);
    }

    function test_decodeAssetRouterBridgehubDepositData_revertsOnWrongVersion() public {
        // Create data with wrong version (0x00 instead of NEW_ENCODING_VERSION)
        bytes memory wrongVersionData = new bytes(100);
        wrongVersionData[0] = bytes1(0x00);

        vm.expectRevert(UnsupportedEncodingVersion.selector);
        this.externalDecodeAssetRouterBridgehubDepositData(wrongVersionData);
    }

    // External wrapper for calldata conversion
    function externalDecodeAssetRouterBridgehubDepositData(
        bytes calldata _data
    ) external pure returns (bytes32, bytes memory) {
        return DataEncoding.decodeAssetRouterBridgehubDepositData(_data);
    }

    // ============ encodeBridgeMintData / decodeBridgeMintData Tests ============

    function test_encodeBridgeMintData_basicValues() public pure {
        address originalCaller = address(0x1111);
        address remoteReceiver = address(0x2222);
        address originToken = address(0x3333);
        uint256 amount = 5000;
        bytes memory erc20Metadata = hex"aabbcc";

        bytes memory encoded = DataEncoding.encodeBridgeMintData(
            originalCaller,
            remoteReceiver,
            originToken,
            amount,
            erc20Metadata
        );

        (
            address decodedCaller,
            address decodedReceiver,
            address decodedToken,
            uint256 decodedAmount,
            bytes memory decodedMetadata
        ) = DataEncoding.decodeBridgeMintData(encoded);

        assertEq(decodedCaller, originalCaller);
        assertEq(decodedReceiver, remoteReceiver);
        assertEq(decodedToken, originToken);
        assertEq(decodedAmount, amount);
        assertEq(keccak256(decodedMetadata), keccak256(erc20Metadata));
    }

    function testFuzz_roundtrip_bridgeMintData(
        address originalCaller,
        address remoteReceiver,
        address originToken,
        uint256 amount
    ) public pure {
        bytes memory erc20Metadata = abi.encode("name", "symbol", uint8(18));

        bytes memory encoded = DataEncoding.encodeBridgeMintData(
            originalCaller,
            remoteReceiver,
            originToken,
            amount,
            erc20Metadata
        );

        (
            address decodedCaller,
            address decodedReceiver,
            address decodedToken,
            uint256 decodedAmount,
            bytes memory decodedMetadata
        ) = DataEncoding.decodeBridgeMintData(encoded);

        assertEq(decodedCaller, originalCaller);
        assertEq(decodedReceiver, remoteReceiver);
        assertEq(decodedToken, originToken);
        assertEq(decodedAmount, amount);
        assertEq(keccak256(decodedMetadata), keccak256(erc20Metadata));
    }

    // ============ encodeAssetId Tests ============

    function test_encodeAssetId_withBytes32() public pure {
        uint256 chainId = 1;
        bytes32 assetData = bytes32(uint256(0x12345));
        address sender = address(0x6789);

        bytes32 assetId = DataEncoding.encodeAssetId(chainId, assetData, sender);

        // Should be deterministic
        bytes32 expected = keccak256(abi.encode(chainId, sender, assetData));
        assertEq(assetId, expected);
    }

    function test_encodeAssetId_withAddress() public pure {
        uint256 chainId = 1;
        address tokenAddress = address(0xABCD);
        address sender = address(0x6789);

        bytes32 assetId = DataEncoding.encodeAssetId(chainId, tokenAddress, sender);

        // Should be deterministic
        bytes32 expected = keccak256(abi.encode(chainId, sender, tokenAddress));
        assertEq(assetId, expected);
    }

    // ============ encodeNTVAssetId Tests ============

    function test_encodeNTVAssetId_withBytes32() public pure {
        uint256 chainId = 1;
        bytes32 assetData = bytes32(uint256(0x12345));

        bytes32 assetId = DataEncoding.encodeNTVAssetId(chainId, assetData);

        // Should use L2_NATIVE_TOKEN_VAULT_ADDR as sender
        bytes32 expected = keccak256(abi.encode(chainId, L2_NATIVE_TOKEN_VAULT_ADDR, assetData));
        assertEq(assetId, expected);
    }

    function test_encodeNTVAssetId_withAddress() public pure {
        uint256 chainId = 1;
        address tokenAddress = address(0xABCD);

        bytes32 assetId = DataEncoding.encodeNTVAssetId(chainId, tokenAddress);

        // Should use L2_NATIVE_TOKEN_VAULT_ADDR as sender
        bytes32 expected = keccak256(abi.encode(chainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress));
        assertEq(assetId, expected);
    }

    // ============ encodeTokenData / decodeTokenData Tests ============

    function test_encodeTokenData_basicValues() public pure {
        uint256 chainId = 42;
        bytes memory name = abi.encode("TestToken");
        bytes memory symbol = abi.encode("TT");
        bytes memory decimals = abi.encode(uint8(18));

        bytes memory encoded = DataEncoding.encodeTokenData(chainId, name, symbol, decimals);

        // Should start with NEW_ENCODING_VERSION
        assertEq(encoded[0], NEW_ENCODING_VERSION);
    }

    function test_decodeTokenData_newEncodingVersion() public {
        uint256 chainId = 42;
        bytes memory name = abi.encode("TestToken");
        bytes memory symbol = abi.encode("TT");
        bytes memory decimals = abi.encode(uint8(18));

        bytes memory encoded = DataEncoding.encodeTokenData(chainId, name, symbol, decimals);

        (
            uint256 decodedChainId,
            bytes memory decodedName,
            bytes memory decodedSymbol,
            bytes memory decodedDecimals
        ) = this.externalDecodeTokenData(encoded);

        assertEq(decodedChainId, chainId);
        assertEq(keccak256(decodedName), keccak256(name));
        assertEq(keccak256(decodedSymbol), keccak256(symbol));
        assertEq(keccak256(decodedDecimals), keccak256(decimals));
    }

    function test_decodeTokenData_revertsOnUnsupportedVersion() public {
        // Create data with unsupported version (0x02)
        bytes memory unsupportedData = new bytes(100);
        unsupportedData[0] = bytes1(0x02);

        vm.expectRevert(UnsupportedEncodingVersion.selector);
        this.externalDecodeTokenData(unsupportedData);
    }

    // External wrapper for calldata conversion
    function externalDecodeTokenData(
        bytes calldata _data
    ) external pure returns (uint256, bytes memory, bytes memory, bytes memory) {
        return DataEncoding.decodeTokenData(_data);
    }

    // ============ getSelector Tests ============

    function test_getSelector_extractsCorrectly() public pure {
        bytes4 expectedSelector = bytes4(0x12345678);
        bytes memory data = abi.encodePacked(expectedSelector, hex"aabbccdd");

        bytes4 extracted = DataEncoding.getSelector(data);
        assertEq(extracted, expectedSelector);
    }

    // ============ encodeInteropWithdrawalCallStarters Tests ============

    /// @notice The withdrawal encoder produces exactly one indirect call to the L2 AssetRouter that carries
    /// ZERO value (both the `indirectCall` message value and `interopCallValue` are 0). This is precisely why
    /// it cannot be used for base-token withdrawals: the base token can only be withdrawn by actually moving
    /// value, whereas this call moves the amount purely inside `_transferData` for the asset handler to release
    /// on L1. Base-token withdrawals instead go through the L2InteropCenter's value-carrying path.
    function test_encodeInteropWithdrawalCallStarters_isZeroValueIndirectCallToAssetRouter() public pure {
        bytes32 assetId = keccak256("some-erc20-asset");
        bytes memory transferData = hex"c0ffee";

        InteropCallStarter[] memory starters = DataEncoding.encodeInteropWithdrawalCallStarters(assetId, transferData);

        assertEq(starters.length, 1, "withdrawal must be a single call");

        InteropCallStarter memory starter = starters[0];
        assertEq(
            starter.to,
            InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            "call must target the L2 AssetRouter"
        );
        assertEq(
            starter.data,
            DataEncoding.encodeAssetRouterBridgehubDepositData(assetId, transferData),
            "call data must be the bridgehub-deposit payload"
        );

        // Exactly two attributes, both encoding a value of 0: indirectCall(0) and interopCallValue(0).
        // Byte-equality against the zero-value encodings proves no base-token value can ride this call.
        assertEq(starter.callAttributes.length, 2, "exactly two call attributes");
        assertEq(
            starter.callAttributes[0],
            abi.encodeCall(IERC7786Attributes.indirectCall, (0)),
            "indirect-call message value must be zero"
        );
        assertEq(
            starter.callAttributes[1],
            abi.encodeCall(IERC7786Attributes.interopCallValue, (0)),
            "interop call value must be zero"
        );
    }

    /// @notice The base-token withdrawal encoder produces the same single indirect call to the L2 AssetRouter,
    /// but with the withdrawn amount riding as the `indirectCall` message value (burned from the `sendBundle`
    /// transaction value). `interopCallValue` must stay zero — destination-side call value is rejected for L1
    /// destinations by the L2InteropCenter.
    function test_encodeInteropBaseTokenWithdrawalCallStarters_carriesAmountAsIndirectCallValue() public pure {
        bytes32 assetId = keccak256("base-token-asset");
        bytes memory transferData = hex"c0ffee";
        uint256 amount = 12 ether;

        InteropCallStarter[] memory starters = DataEncoding.encodeInteropBaseTokenWithdrawalCallStarters(
            assetId,
            transferData,
            amount
        );

        assertEq(starters.length, 1, "withdrawal must be a single call");

        InteropCallStarter memory starter = starters[0];
        assertEq(
            starter.to,
            InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            "call must target the L2 AssetRouter"
        );
        assertEq(
            starter.data,
            DataEncoding.encodeAssetRouterBridgehubDepositData(assetId, transferData),
            "call data must be the bridgehub-deposit payload"
        );

        assertEq(starter.callAttributes.length, 2, "exactly two call attributes");
        assertEq(
            starter.callAttributes[0],
            abi.encodeCall(IERC7786Attributes.indirectCall, (amount)),
            "withdrawn amount must ride as the indirect-call message value"
        );
        assertEq(
            starter.callAttributes[1],
            abi.encodeCall(IERC7786Attributes.interopCallValue, (0)),
            "interop call value must be zero"
        );
    }
}
