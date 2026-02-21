// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {TokenIsLegacy, TokenNotLegacy} from "contracts/common/L1ContractErrors.sol";

abstract contract L2NativeTokenVaultLegacyTokenTestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    function _setLegacyBridgeMapping(address _l2Token, address _l1Token) internal {
        stdstore.target(sharedBridgeLegacy).sig("l1TokenAddress(address)").with_key(_l2Token).checked_write(_l1Token);
    }

    function test_registerLegacyToken() external {
        address l2Token = address(new TestnetERC20Token("LegacyToken", "LGC", 18));
        address l1Token = makeAddr("l1Token");
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);

        // Verify token is not registered before
        assertEq(l2NativeTokenVault.assetId(l2Token), bytes32(0), "Asset ID should be zero before registration");

        _setLegacyBridgeMapping(l2Token, l1Token);
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
        address l2Token = address(new TestnetERC20Token("LegacyToken", "LGC", 18));
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

        _setLegacyBridgeMapping(l2Token, l1Token);
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
        _setLegacyBridgeMapping(l2Token, l1Token);

        vm.expectRevert(TokenIsLegacy.selector);
        INativeTokenVaultBase(L2_NATIVE_TOKEN_VAULT_ADDR).registerToken(l2Token);
    }
}
