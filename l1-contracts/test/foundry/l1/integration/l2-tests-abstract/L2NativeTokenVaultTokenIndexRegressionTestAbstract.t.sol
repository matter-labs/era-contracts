// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {TokenAlreadyInBridgedTokensList} from "contracts/bridge/L1BridgeContractErrors.sol";

import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";

abstract contract L2NativeTokenVaultTokenIndexRegressionTestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    function test_regression_setLegacyTokenDataSetsTokenIndex() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        // First, add a dummy token to avoid the sentinel-0 issue
        // This ensures bridgedTokensCount > 0 before our test token
        address dummyL2Token = makeAddr("dummyL2Token");
        address dummyL1Token = makeAddr("dummyL1Token");
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (dummyL2Token)),
            abi.encode(dummyL1Token)
        );
        l2NativeTokenVault.setLegacyTokenAssetId(dummyL2Token);

        // Now set up the actual test token
        address l2Token = makeAddr("l2LegacyToken");
        address l1Token = makeAddr("l1Token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);

        // Mock the legacy bridge to return the L1 token address
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (l2Token)),
            abi.encode(l1Token)
        );

        // Verify initial state
        uint256 initialCount = l2NativeTokenVault.bridgedTokensCount();
        assertTrue(initialCount > 0, "Should have at least one token from dummy setup");
        assertEq(l2NativeTokenVault.tokenIndex(assetId), 0, "tokenIndex should be 0 initially for our test asset");

        // Register the legacy token - this calls _setLegacyTokenData internally
        l2NativeTokenVault.setLegacyTokenAssetId(l2Token);

        // Verify the token was added to bridgedTokens
        uint256 newCount = l2NativeTokenVault.bridgedTokensCount();
        assertEq(newCount, initialCount + 1, "bridgedTokensCount should increment by 1");

        // THE KEY ASSERTION: tokenIndex should be set to the index (which is > 0 due to dummy token)
        // Before the fix: tokenIndex[assetId] would still be 0 (never set)
        // After the fix: tokenIndex[assetId] should equal initialCount (the position)
        uint256 tokenIndexValue = l2NativeTokenVault.tokenIndex(assetId);
        assertEq(tokenIndexValue, initialCount, "tokenIndex should equal the position in bridgedTokens array");
        assertTrue(tokenIndexValue > 0, "tokenIndex should be > 0 (not sentinel value)");

        // Verify the bridgedTokens array contains the correct assetId at that index
        assertEq(l2NativeTokenVault.bridgedTokens(initialCount), assetId, "bridgedTokens should contain the assetId");
    }

    /// @notice Test that addLegacyTokenToBridgedTokensList now correctly rejects duplicates
    /// @dev This tests the scenario that was broken before the fix (with sentinel-0 workaround)
    function test_regression_addLegacyTokenToBridgedTokensListRejectsDuplicateAfterSetLegacy() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        // First, add a dummy token to move past index 0
        address dummyL2Token = makeAddr("dummyL2Token");
        address dummyL1Token = makeAddr("dummyL1Token");
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (dummyL2Token)),
            abi.encode(dummyL1Token)
        );
        l2NativeTokenVault.setLegacyTokenAssetId(dummyL2Token);

        address l2Token = makeAddr("l2LegacyToken");
        address l1Token = makeAddr("l1Token");

        // Mock the legacy bridge
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (l2Token)),
            abi.encode(l1Token)
        );

        // Register as legacy token (this sets tokenIndex to a value > 0)
        l2NativeTokenVault.setLegacyTokenAssetId(l2Token);

        uint256 countAfterFirstAdd = l2NativeTokenVault.bridgedTokensCount();

        // Now try to add via addLegacyTokenToBridgedTokensList - should revert
        // Before the fix: This would succeed and create a duplicate
        // After the fix: This should revert with TokenAlreadyInBridgedTokensList
        vm.expectRevert(TokenAlreadyInBridgedTokensList.selector);
        l2NativeTokenVault.addLegacyTokenToBridgedTokensList(l2Token);

        // Verify count hasn't changed (no duplicate was added)
        assertEq(
            l2NativeTokenVault.bridgedTokensCount(),
            countAfterFirstAdd,
            "bridgedTokensCount should not change when duplicate is rejected"
        );
    }

    /// @notice Test the complete attack scenario that was possible before the fix
    /// @dev Demonstrates that the bug could have led to duplicate entries (with sentinel-0 workaround)
    function test_regression_legacyTokenNoDuplicateEntries() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        // First, add a dummy token to move past index 0
        address dummyL2Token = makeAddr("dummyL2Token");
        address dummyL1Token = makeAddr("dummyL1Token");
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (dummyL2Token)),
            abi.encode(dummyL1Token)
        );
        l2NativeTokenVault.setLegacyTokenAssetId(dummyL2Token);

        address l2Token = makeAddr("l2Token");
        address l1Token = makeAddr("l1Token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);

        // Mock legacy bridge
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (l2Token)),
            abi.encode(l1Token)
        );

        // Step 1: Register legacy token via setLegacyTokenAssetId
        l2NativeTokenVault.setLegacyTokenAssetId(l2Token);

        uint256 countAfterRegister = l2NativeTokenVault.bridgedTokensCount();
        uint256 tokenIndexAfterRegister = l2NativeTokenVault.tokenIndex(assetId);

        // Verify proper state after registration - tokenIndex > 0 since we added dummy first
        assertTrue(tokenIndexAfterRegister > 0, "Token should have non-zero index");

        // Step 2: Try to add the same token via addLegacyTokenToBridgedTokensList
        // Before fix: tokenIndex[assetId] == 0 (never set), so this would pass and add duplicate
        // After fix: tokenIndex[assetId] > 0, so this reverts
        vm.expectRevert(TokenAlreadyInBridgedTokensList.selector);
        l2NativeTokenVault.addLegacyTokenToBridgedTokensList(l2Token);

        // Step 3: Verify no duplicate was created
        uint256 countAfterDuplicateAttempt = l2NativeTokenVault.bridgedTokensCount();
        assertEq(
            countAfterDuplicateAttempt,
            countAfterRegister,
            "Count should remain same - no duplicate should be possible"
        );

        // Step 4: Verify the token only appears once in bridgedTokens
        uint256 appearances = 0;
        for (uint256 i = 0; i < countAfterDuplicateAttempt; i++) {
            if (l2NativeTokenVault.bridgedTokens(i) == assetId) {
                appearances++;
            }
        }
        assertEq(appearances, 1, "Asset should appear exactly once in bridgedTokens array");
    }

    /// @notice Test that bridgeMint for legacy tokens also correctly sets tokenIndex
    /// @dev The bridgeMint path also goes through _setLegacyTokenData for legacy tokens
    function test_regression_bridgeMintLegacyTokenSetsTokenIndex() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        // First, add a dummy token to move past index 0
        address dummyL2Token = makeAddr("dummyL2Token");
        address dummyL1Token = makeAddr("dummyL1Token");
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (dummyL2Token)),
            abi.encode(dummyL1Token)
        );
        l2NativeTokenVault.setLegacyTokenAssetId(dummyL2Token);

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

        // Verify initial state
        uint256 initialCount = l2NativeTokenVault.bridgedTokensCount();
        assertTrue(initialCount > 0, "Should have at least one token from dummy setup");
        assertEq(l2NativeTokenVault.tokenIndex(assetId), 0, "tokenIndex should be 0 initially");

        // Mock legacy bridge to trigger the legacy token path
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (expectedL2TokenAddress)),
            abi.encode(originToken)
        );
        vm.mockCall(expectedL2TokenAddress, abi.encodeCall(IBridgedStandardToken.bridgeMint, (receiver, amount)), "");
        vm.mockCall(expectedL2TokenAddress, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(amount));

        // Perform bridge mint - this will call _setLegacyTokenData
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(address(l2NativeTokenVault)).bridgeMint(originChainId, assetId, data);

        // Verify tokenIndex was set (should be > 0 since we added dummy first)
        uint256 tokenIndexValue = l2NativeTokenVault.tokenIndex(assetId);
        assertTrue(tokenIndexValue > 0, "tokenIndex should be > 0 after bridgeMint for legacy token");
        assertEq(tokenIndexValue, initialCount, "tokenIndex should equal position in bridgedTokens array");

        // Now try to add via addLegacyTokenToBridgedTokensList - should reject
        vm.expectRevert(TokenAlreadyInBridgedTokensList.selector);
        l2NativeTokenVault.addLegacyTokenToBridgedTokensList(expectedL2TokenAddress);
    }

    /// @notice Test the consistency of tokenIndex and bridgedTokens array
    /// @dev Verifies that _addTokenToTokensList properly maintains the mapping
    function testFuzz_regression_legacyTokenIndexConsistency(address l2Token, address l1Token) external {
        vm.assume(l2Token != address(0));
        vm.assume(l1Token != address(0));
        vm.assume(l2Token != l1Token);

        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);

        // Skip if this token is already registered
        if (l2NativeTokenVault.assetId(l2Token) != bytes32(0)) {
            return;
        }

        // Mock legacy bridge
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (l2Token)),
            abi.encode(l1Token)
        );

        uint256 countBefore = l2NativeTokenVault.bridgedTokensCount();

        // Register
        l2NativeTokenVault.setLegacyTokenAssetId(l2Token);

        // Verify tokenIndex is properly set to the array index
        uint256 tokenIdx = l2NativeTokenVault.tokenIndex(assetId);
        assertEq(tokenIdx, countBefore, "tokenIndex should equal the index where token was added");

        // Verify bridgedTokens at that index is the assetId
        assertEq(l2NativeTokenVault.bridgedTokens(tokenIdx), assetId, "bridgedTokens[tokenIndex] should be assetId");

        // Verify count increased
        assertEq(l2NativeTokenVault.bridgedTokensCount(), countBefore + 1, "bridgedTokensCount should increase");
    }

    /// @notice Test that verifies the index is correctly set even for the first token (sentinel-0 case)
    /// @dev This documents the sentinel-0 behavior - tokenIndex[assetId] = 0 for the first token
    function test_regression_firstTokenSentinelZeroBehavior() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        // Assume this is the first token (bridgedTokensCount == 0)
        // Note: In practice, there may be tokens already registered during setup
        uint256 initialCount = l2NativeTokenVault.bridgedTokensCount();

        address l2Token = makeAddr("firstToken");
        address l1Token = makeAddr("firstL1Token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);

        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (l2Token)),
            abi.encode(l1Token)
        );

        // Register the token
        l2NativeTokenVault.setLegacyTokenAssetId(l2Token);

        // After the fix, tokenIndex is SET to the array index
        // For the first token, this is 0 (or initialCount if there were already tokens)
        uint256 tokenIdx = l2NativeTokenVault.tokenIndex(assetId);
        assertEq(tokenIdx, initialCount, "tokenIndex should equal the array position");

        // Verify the mapping is correct
        assertEq(l2NativeTokenVault.bridgedTokens(tokenIdx), assetId, "bridgedTokens[tokenIndex] should be correct");
    }
}
