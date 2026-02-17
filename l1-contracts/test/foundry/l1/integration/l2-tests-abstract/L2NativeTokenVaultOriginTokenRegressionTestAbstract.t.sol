// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";

abstract contract L2NativeTokenVaultOriginTokenRegressionTestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    function test_regression_originTokenReturnsCorrectAddressForBridgedToken() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        // Set up a bridged token scenario
        // originChainId should be different from block.chainid (L1 chain)
        uint256 originChainId = L1_CHAIN_ID;
        address originToken = makeAddr("l1OriginToken");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(originChainId, originToken);

        // Calculate the expected L2 token address (bridged token)
        address expectedL2TokenAddress = l2NativeTokenVault.calculateCreate2TokenAddress(originChainId, originToken);

        // Set up the token state using stdstore
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig(INativeTokenVaultBase.tokenAddress.selector)
            .with_key(assetId)
            .checked_write(expectedL2TokenAddress);

        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig(INativeTokenVaultBase.originChainId.selector)
            .with_key(assetId)
            .checked_write(originChainId);

        // Mock the bridged token's originToken() call
        // IBridgedStandardToken(l2Token).originToken() should return the L1 origin token
        vm.mockCall(
            expectedL2TokenAddress,
            abi.encodeCall(IBridgedStandardToken.originToken, ()),
            abi.encode(originToken)
        );

        // Verify this is a bridged token scenario (originChainId != block.chainid)
        assertNotEq(originChainId, block.chainid, "This should be a bridged token scenario");

        // Call originToken(assetId)
        // Before the fix: would return address(0) because the return was missing
        // After the fix: should return the correct origin token address
        address returnedOriginToken = l2NativeTokenVault.originToken(assetId);

        // The key assertion - this failed before the fix
        assertEq(
            returnedOriginToken,
            originToken,
            "originToken should return the correct L1 origin token for bridged assets"
        );

        // Additional check: verify it's not address(0)
        assertTrue(
            returnedOriginToken != address(0),
            "originToken should not return address(0) for valid bridged assets"
        );
    }

    /// @notice Test that originToken returns address(0) for non-existent assets
    /// @dev This tests the first branch of originToken where tokenAddress[_assetId] == address(0)
    function test_regression_originTokenReturnsZeroForNonExistentAsset() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        // Create an asset ID that doesn't exist
        bytes32 nonExistentAssetId = keccak256("nonExistentAsset");

        // Verify the asset doesn't exist
        assertEq(l2NativeTokenVault.tokenAddress(nonExistentAssetId), address(0));

        // originToken should return address(0) for non-existent assets
        address returnedOriginToken = l2NativeTokenVault.originToken(nonExistentAssetId);
        assertEq(returnedOriginToken, address(0), "originToken should return address(0) for non-existent assets");
    }

    /// @notice Test that originToken returns the token address directly for native tokens
    /// @dev This tests the second branch where originChainId[_assetId] == block.chainid
    function test_regression_originTokenReturnsTokenAddressForNativeToken() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        // Set up a native token scenario (token originated on current chain)
        uint256 originChainId = block.chainid; // Same as current chain
        address nativeToken = makeAddr("nativeToken");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(originChainId, nativeToken);

        // Set up the token state
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig(INativeTokenVaultBase.tokenAddress.selector)
            .with_key(assetId)
            .checked_write(nativeToken);

        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig(INativeTokenVaultBase.originChainId.selector)
            .with_key(assetId)
            .checked_write(originChainId);

        // Verify this is a native token scenario
        assertEq(l2NativeTokenVault.originChainId(assetId), block.chainid);

        // originToken should return the token address directly for native tokens
        address returnedOriginToken = l2NativeTokenVault.originToken(assetId);
        assertEq(returnedOriginToken, nativeToken, "originToken should return the token address for native tokens");
    }

    /// @notice Test the complete flow: bridge mint followed by originToken lookup
    /// @dev Integration test ensuring bridged tokens can be correctly queried
    function test_regression_originTokenWorksAfterBridgeMint() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        uint256 originChainId = L1_CHAIN_ID;
        address originToken = makeAddr("l1Token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(originChainId, originToken);

        address expectedL2TokenAddress = l2NativeTokenVault.calculateCreate2TokenAddress(originChainId, originToken);

        address depositor = makeAddr("depositor");
        address receiver = makeAddr("receiver");
        uint256 amount = 100;
        bytes memory erc20Metadata = DataEncoding.encodeTokenData(
            originChainId,
            abi.encode("Token"),
            abi.encode("T"),
            abi.encode(18)
        );
        bytes memory data = DataEncoding.encodeBridgeMintData(depositor, receiver, originToken, amount, erc20Metadata);

        // Mock legacy bridge to trigger the legacy token path
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (expectedL2TokenAddress)),
            abi.encode(originToken)
        );
        vm.mockCall(expectedL2TokenAddress, abi.encodeCall(IBridgedStandardToken.bridgeMint, (receiver, amount)), "");
        vm.mockCall(expectedL2TokenAddress, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(amount));

        // Perform bridge mint
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(address(l2NativeTokenVault)).bridgeMint(originChainId, assetId, data);

        // Now mock the originToken call on the bridged token
        vm.mockCall(
            expectedL2TokenAddress,
            abi.encodeCall(IBridgedStandardToken.originToken, ()),
            abi.encode(originToken)
        );

        // Call originToken and verify it returns the correct L1 origin token
        // Before the fix: would return address(0)
        // After the fix: should return originToken
        address returnedOriginToken = l2NativeTokenVault.originToken(assetId);

        assertEq(returnedOriginToken, originToken, "originToken should return correct L1 token after bridge mint");
        assertTrue(returnedOriginToken != address(0), "originToken should not be zero for bridged token");
    }
}
