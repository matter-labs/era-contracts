// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";

import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";

import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";

abstract contract L2NativeTokenVaultBridgeMintTestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

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

        // Perform a real bridge mint: the NTV deploys the bridged token via CREATE2 at `expectedL2TokenAddress`
        // and mints to the receiver. We deliberately do NOT mock the token (a mock would inject code at the deploy
        // target and collide with CREATE2).
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IAssetHandler(address(l2NativeTokenVault)).bridgeMint(originChainId, assetId, data);

        assertNotEq(l2NativeTokenVault.originChainId(assetId), 0);
        assertNotEq(l2NativeTokenVault.tokenAddress(assetId), address(0));
        assertNotEq(l2NativeTokenVault.assetId(expectedL2TokenAddress), bytes32(0));
        assertEq(l2NativeTokenVault.originChainId(assetId), originChainId);
        assertEq(l2NativeTokenVault.tokenAddress(assetId), expectedL2TokenAddress);
        assertEq(l2NativeTokenVault.assetId(expectedL2TokenAddress), assetId);
    }
}
