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

import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IBaseToken} from "contracts/common/l2-helpers/IBaseToken.sol";

abstract contract L2NativeTokenVaultTestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    function test_registerLegacyToken() external {
        address l2Token = makeAddr("l2Token");
        address l1Token = makeAddr("l1Token");
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (l2Token)),
            abi.encode(l1Token)
        );
        L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).setLegacyTokenAssetId(l2Token);
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

    /*//////////////////////////////////////////////////////////////
                    Regression Tests for PR #1704
                    originToken Return Value Fix
    //////////////////////////////////////////////////////////////*/

    /// @notice Regression test for the bug fixed in PR #1704 (commit 68ab974)
    /// @dev Bug Description:
    ///      NativeTokenVaultBase.originToken(bytes32) was missing a return statement in the
    ///      bridged-token branch. The function called `_getOriginTokenFromAddress(token)` but
    ///      didn't return the result, causing the function to fall through and return address(0)
    ///      for bridged assets.
    ///
    ///      This caused callers relying on this getter to misroute or fail when resolving
    ///      the origin token for bridged assets.
    ///
    ///      Fix: Changed `_getOriginTokenFromAddress(token);` to `return _getOriginTokenFromAddress(token);`
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
        assertTrue(returnedOriginToken != address(0), "originToken should not return address(0) for valid bridged assets");
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

        assertEq(
            returnedOriginToken,
            originToken,
            "originToken should return correct L1 token after bridge mint"
        );
        assertTrue(returnedOriginToken != address(0), "originToken should not be zero for bridged token");
    }

    /*//////////////////////////////////////////////////////////////
                    Regression Tests for PR #1776
                    Base Token Bridge Burn Fix
    //////////////////////////////////////////////////////////////*/

    /// @notice Regression test for the bug fixed in PR #1776
    /// @dev Bug Description:
    ///      When a user tries to send a bundle that includes a transfer of the sending chain's
    ///      base token, an indirect call would be triggered. The NativeTokenVault would try to
    ///      handle it via the bridged token path (_bridgeBurnBridgedToken), which calls:
    ///
    ///      IBridgedStandardToken(_tokenAddress).bridgeBurn(_originalCaller, _depositAmount);
    ///
    ///      However, the base token (L2_BASE_TOKEN_SYSTEM_CONTRACT) does not implement the
    ///      IBridgedStandardToken.bridgeBurn function, causing the transaction to fail.
    ///
    ///      Fix: In _getTokenAndBridgeToChain, check if _assetId == _baseTokenAssetId().
    ///      If true AND _isBridgedToken, call L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue()
    ///      instead of trying to call bridgeBurn on the token address.
    ///
    /// @dev This test verifies that bridgeBurn works correctly for the base token when
    ///      it goes through the bridged token path (originChainId != block.chainid)
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
        assertNotEq(storedOriginChainId, block.chainid, "Base token should be considered bridged (originChainId != block.chainid)");

        // Prepare bridgeBurn parameters
        uint256 destinationChainId = 12345;
        uint256 depositAmount = 1 ether;
        address receiver = makeAddr("receiver");
        address originalCaller = makeAddr("originalCaller");
        // Data format: (amount, receiver, tokenAddress) - tokenAddress=0 means use stored address
        bytes memory data = abi.encode(depositAmount, receiver, address(0));

        // Deal ETH to the asset router (needed because bridgeBurn is called with msg.value)
        vm.deal(L2_ASSET_ROUTER_ADDR, depositAmount);

        // Mock the burnMsgValue call on L2_BASE_TOKEN_SYSTEM_CONTRACT
        // Before the fix: This wouldn't be called, and bridgeBurn would fail
        // After the fix: This should be called with the correct value
        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            depositAmount,
            abi.encodeCall(IBaseToken.burnMsgValue, ()),
            abi.encode()
        );

        // Expect the burnMsgValue call
        vm.expectCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            depositAmount,
            abi.encodeCall(IBaseToken.burnMsgValue, ())
        );

        // Call bridgeBurn from the asset router (which is the only allowed caller)
        // Before the fix: This would revert because bridgeBurn would try to call
        // IBridgedStandardToken(L2_BASE_TOKEN_SYSTEM_CONTRACT).bridgeBurn() which doesn't exist
        // After the fix: This should succeed and call burnMsgValue instead
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(address(l2NativeTokenVault)).bridgeBurn{value: depositAmount}(
            destinationChainId,
            0, // _msgValue (unused in this context)
            baseTokenAssetIdLocal,
            originalCaller,
            data
        );

        // If we reach here, the fix is working - burnMsgValue was called instead of bridgeBurn
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
        address expectedL2TokenAddress = l2NativeTokenVault.calculateCreate2TokenAddress(originChainIdLocal, originToken);

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
        IAssetHandler(address(l2NativeTokenVault)).bridgeBurn(
            destinationChainId,
            0,
            assetId,
            originalCaller,
            data
        );

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
}
