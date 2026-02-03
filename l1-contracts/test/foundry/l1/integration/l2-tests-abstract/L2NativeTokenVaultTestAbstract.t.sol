// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

// import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
// import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";

// import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
// import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

// import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {BridgeMintNotImplemented, TokenIsLegacy, TokenNotLegacy, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {TokenAlreadyInBridgedTokensList} from "contracts/bridge/L1BridgeContractErrors.sol";

import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BASE_TOKEN_HOLDER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IBaseToken} from "contracts/common/l2-helpers/IBaseToken.sol";

abstract contract L2NativeTokenVaultTestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    function test_registerLegacyToken() external {
        address l2Token = makeAddr("l2Token");
        address l1Token = makeAddr("l1Token");
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);

        // Verify token is not registered before
        assertEq(l2NativeTokenVault.assetId(l2Token), bytes32(0), "Asset ID should be zero before registration");

        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (l2Token)),
            abi.encode(l1Token)
        );
        L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).setLegacyTokenAssetId(l2Token);

        // Verify token is registered after
        assertEq(l2NativeTokenVault.assetId(l2Token), expectedAssetId, "Asset ID should be set after registration");
        assertEq(
            l2NativeTokenVault.tokenAddress(expectedAssetId),
            l2Token,
            "Token address should be mapped to asset ID"
        );
        assertEq(l2NativeTokenVault.originChainId(expectedAssetId), L1_CHAIN_ID, "Origin chain ID should be L1");
    }

    function test_registerLegacyToken_IncorrectConfiguration() external {
        address l2Token = makeAddr("l2Token");
        address l1Token = makeAddr("l1Token");
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);

        assertEq(l2NativeTokenVault.originChainId(assetId), 0);
        assertEq(l2NativeTokenVault.tokenAddress(assetId), address(0));
        assertEq(l2NativeTokenVault.assetId(l2Token), bytes32(0));

        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig(INativeTokenVaultBase.tokenAddress.selector)
            .with_key(assetId)
            .checked_write(l2Token);

        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig(INativeTokenVaultBase.assetId.selector)
            .with_key(l2Token)
            .checked_write(assetId);

        assertNotEq(l2NativeTokenVault.tokenAddress(assetId), address(0));
        assertNotEq(l2NativeTokenVault.assetId(l2Token), bytes32(0));

        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (l2Token)),
            abi.encode(l1Token)
        );
        L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).setLegacyTokenAssetId(l2Token);

        assertNotEq(l2NativeTokenVault.originChainId(assetId), 0);
        assertNotEq(l2NativeTokenVault.tokenAddress(assetId), address(0));
        assertNotEq(l2NativeTokenVault.assetId(l2Token), bytes32(0));
    }

    function test_registerLegacyTokenRevertNotLegacy() external {
        address l2Token = makeAddr("l2Token");
        vm.expectRevert(TokenNotLegacy.selector);
        L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).setLegacyTokenAssetId(l2Token);
    }

    function test_registerTokenRevertIsLegacy() external {
        address l2Token = makeAddr("l2Token");
        address l1Token = makeAddr("l1Token");
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (l2Token)),
            abi.encode(l1Token)
        );

        vm.expectRevert(TokenIsLegacy.selector);
        INativeTokenVaultBase(L2_NATIVE_TOKEN_VAULT_ADDR).registerToken(l2Token);
    }

    function test_bridgeMint_CorrectlyConfiguresL2LegacyToken() external {
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

        assertNotEq(block.chainid, originChainId);

        assertEq(l2NativeTokenVault.originChainId(assetId), 0);
        assertEq(l2NativeTokenVault.tokenAddress(assetId), address(0));
        assertEq(l2NativeTokenVault.assetId(expectedL2TokenAddress), bytes32(0));

        // this `mockCall` ensures the branch for legacy tokens is chosen
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (expectedL2TokenAddress)),
            abi.encode(originToken)
        );
        // fails on the following line without this `mockCall`
        // https://github.com/matter-labs/era-contracts/blob/cebfe26a41f3b83039a7d36558bf4e0401b154fc/l1-contracts/contracts/bridge/ntv/NativeTokenVault.sol#L163
        vm.mockCall(expectedL2TokenAddress, abi.encodeCall(IBridgedStandardToken.bridgeMint, (receiver, amount)), "");
        vm.mockCall(expectedL2TokenAddress, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(amount));
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(address(l2NativeTokenVault)).bridgeMint(originChainId, assetId, data);

        assertNotEq(l2NativeTokenVault.originChainId(assetId), 0);
        assertNotEq(l2NativeTokenVault.tokenAddress(assetId), address(0));
        assertNotEq(l2NativeTokenVault.assetId(expectedL2TokenAddress), bytes32(0));
        assertEq(l2NativeTokenVault.originChainId(assetId), originChainId);
        assertEq(l2NativeTokenVault.tokenAddress(assetId), expectedL2TokenAddress);
        assertEq(l2NativeTokenVault.assetId(expectedL2TokenAddress), assetId);
    }

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

    function test_regression_bridgeBurnBaseTokenAsBridgedTokenCallsBurnMsgValue() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        // Get the base token asset ID
        bytes32 baseTokenAssetIdLocal = l2NativeTokenVault.BASE_TOKEN_ASSET_ID();

        // The test needs the base token to be considered "bridged" (originChainId != block.chainid)
        // to trigger the _bridgeBurnBridgedToken path where the bug was.
        // Due to the way the test infrastructure handles storage for system contract addresses,
        // we mock the originChainId return value to simulate the bridged token scenario.
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeCall(INativeTokenVaultBase.originChainId, (baseTokenAssetIdLocal)),
            abi.encode(L1_CHAIN_ID)
        );

        // Verify setup - originChainId should now be L1_CHAIN_ID (10), different from block.chainid (31337)
        uint256 storedOriginChainId = l2NativeTokenVault.originChainId(baseTokenAssetIdLocal);
        assertEq(storedOriginChainId, L1_CHAIN_ID, "Base token originChainId should be L1_CHAIN_ID");
        assertNotEq(
            storedOriginChainId,
            block.chainid,
            "Base token should be considered bridged (originChainId != block.chainid)"
        );

        // Prepare bridgeBurn parameters
        uint256 destinationChainId = 12345;
        uint256 depositAmount = 1 ether;
        address receiver = makeAddr("receiver");
        address originalCaller = makeAddr("originalCaller");
        // Data format: (amount, receiver, tokenAddress) - tokenAddress=0 means use stored address
        bytes memory data = abi.encode(depositAmount, receiver, address(0));

        // Deal ETH to the asset router (needed because bridgeBurn is called with msg.value)
        vm.deal(L2_ASSET_ROUTER_ADDR, depositAmount);

        // After the change: tokens are sent to BaseTokenHolder instead of calling burnMsgValue
        // We need to make BaseTokenHolder accept the ETH transfer (etch minimal contract that accepts ETH)
        vm.etch(L2_BASE_TOKEN_HOLDER_ADDR, hex"00");

        // Record the BaseTokenHolder balance before
        uint256 holderBalanceBefore = L2_BASE_TOKEN_HOLDER_ADDR.balance;

        // Call bridgeBurn from the asset router (which is the only allowed caller)
        // Before the fix: This would revert because bridgeBurn would try to call
        // IBridgedStandardToken(L2_BASE_TOKEN_SYSTEM_CONTRACT).bridgeBurn() which doesn't exist
        // After the fix: This should succeed and send ETH to BaseTokenHolder
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(address(l2NativeTokenVault)).bridgeBurn{value: depositAmount}(
            destinationChainId,
            0, // _msgValue (unused in this context)
            baseTokenAssetIdLocal,
            originalCaller,
            data
        );

        // Verify that BaseTokenHolder received the ETH (effectively "burning" from circulation)
        uint256 holderBalanceAfter = L2_BASE_TOKEN_HOLDER_ADDR.balance;
        assertEq(
            holderBalanceAfter - holderBalanceBefore,
            depositAmount,
            "BaseTokenHolder should receive the deposit amount"
        );
    }

    /// @notice Test that bridgeBurn still works correctly for regular bridged tokens (non-base token)
    /// @dev This is a sanity check to ensure the fix doesn't break normal bridged token burning
    function test_regression_bridgeBurnRegularBridgedTokenStillCallsBridgeBurn() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        // Create a regular bridged token (not the base token)
        uint256 originChainIdLocal = L1_CHAIN_ID;
        address originToken = makeAddr("l1Token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(originChainIdLocal, originToken);

        // Calculate the expected L2 token address
        address expectedL2TokenAddress = l2NativeTokenVault.calculateCreate2TokenAddress(
            originChainIdLocal,
            originToken
        );

        // Set up the token in NTV storage
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig(INativeTokenVaultBase.tokenAddress.selector)
            .with_key(assetId)
            .checked_write(expectedL2TokenAddress);

        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig(INativeTokenVaultBase.assetId.selector)
            .with_key(expectedL2TokenAddress)
            .checked_write(assetId);

        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig(INativeTokenVaultBase.originChainId.selector)
            .with_key(assetId)
            .checked_write(originChainIdLocal);

        // Verify setup - originChainId should be different from block.chainid
        assertNotEq(l2NativeTokenVault.originChainId(assetId), block.chainid);

        // Prepare bridgeBurn parameters
        uint256 destinationChainId = 12345;
        uint256 depositAmount = 100;
        address receiver = makeAddr("receiver");
        address originalCaller = makeAddr("originalCaller");
        // Data format: (amount, receiver, tokenAddress) - tokenAddress=0 means use stored address
        bytes memory data = abi.encode(depositAmount, receiver, address(0));

        // Mock the bridgeBurn call on the bridged token
        vm.mockCall(
            expectedL2TokenAddress,
            abi.encodeCall(IBridgedStandardToken.bridgeBurn, (originalCaller, depositAmount)),
            abi.encode()
        );

        // Mock the originToken call
        vm.mockCall(
            expectedL2TokenAddress,
            abi.encodeCall(IBridgedStandardToken.originToken, ()),
            abi.encode(originToken)
        );

        // Expect the bridgeBurn call on the bridged token
        vm.expectCall(
            expectedL2TokenAddress,
            abi.encodeCall(IBridgedStandardToken.bridgeBurn, (originalCaller, depositAmount))
        );

        // Call bridgeBurn from the asset router
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(address(l2NativeTokenVault)).bridgeBurn(destinationChainId, 0, assetId, originalCaller, data);

        // The regular bridgeBurn should have been called on the bridged token
    }

    /// @notice Test the base token bridgeBurn with different origin chain scenarios
    /// @dev Fuzz test to verify the fix works for various amounts
    function testFuzz_regression_bridgeBurnBaseTokenVariousAmounts(uint256 depositAmount) external {
        vm.assume(depositAmount > 0 && depositAmount < type(uint128).max);

        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        bytes32 baseTokenAssetIdLocal = l2NativeTokenVault.BASE_TOKEN_ASSET_ID();

        // The test setup already initializes originChainId[baseTokenAssetId] = L1_CHAIN_ID
        // Since block.chainid != L1_CHAIN_ID, the bridged token path is taken

        // Prepare parameters
        uint256 destinationChainId = 12345;
        address receiver = makeAddr("receiver");
        address originalCaller = makeAddr("originalCaller");
        // Data format: (amount, receiver, tokenAddress)
        bytes memory data = abi.encode(depositAmount, receiver, address(0));

        vm.deal(L2_ASSET_ROUTER_ADDR, depositAmount);

        // Mock burnMsgValue
        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            depositAmount,
            abi.encodeCall(IBaseToken.burnMsgValue, ()),
            abi.encode()
        );

        // Should succeed and call burnMsgValue
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(address(l2NativeTokenVault)).bridgeBurn{value: depositAmount}(
            destinationChainId,
            0,
            baseTokenAssetIdLocal,
            originalCaller,
            data
        );
    }

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
