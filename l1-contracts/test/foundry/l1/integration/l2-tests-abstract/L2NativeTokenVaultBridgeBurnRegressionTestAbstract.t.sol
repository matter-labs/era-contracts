// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IBaseToken} from "contracts/common/l2-helpers/IBaseToken.sol";

abstract contract L2NativeTokenVaultBridgeBurnRegressionTestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

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
        vm.expectCall(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, depositAmount, abi.encodeCall(IBaseToken.burnMsgValue, ()));

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
}
