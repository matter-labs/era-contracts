// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IBridgedStandardToken} from "contracts/bridge/interfaces/IBridgedStandardToken.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {BridgehubMintCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {SystemContractsArgs} from "./_SharedL2ContractL1DeployerUtils.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {TokenIsLegacy, TokenIsNotLegacy, Unauthorized, BridgeMintNotImplemented} from "contracts/common/L1ContractErrors.sol";

import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";

abstract contract L2NativeTokenVaultTestAbstract is Test, SharedL2ContractDeployer {
    function test_registerLegacyToken() external {
        address l2Token = makeAddr("l2Token");
        address l1Token = makeAddr("l1Token");
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (l2Token)),
            abi.encode(l1Token)
        );
        L2NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy).setLegacyTokenAssetId(l2Token);
    }

    function test_registerLegacyTokenRevertNotLegacy() external {
        address l2Token = makeAddr("l2Token");
        vm.expectRevert(TokenIsNotLegacy.selector);
        L2NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy).setLegacyTokenAssetId(l2Token);
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
        L2NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy).registerToken(l2Token);
    }

    function test_bridgeMint_CorrectlyConfiguresL2LegacyToken() external {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy);

        uint256 originChainId = L1_CHAIN_ID;
        address originToken = makeAddr("l1Token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(originChainId, originToken);

        address expectedL2TokenAddress = l2NativeTokenVault.calculateCreate2TokenAddress(originChainId, originToken);

        address depositor = makeAddr("depositor");
        address receiver = makeAddr("receiver");
        uint256 amount = 100;
        bytes memory erc20Metadata = DataEncoding.encodeTokenData(originChainId, abi.encode("Token"), abi.encode("T"), abi.encode(18));
        bytes memory data = DataEncoding.encodeBridgeMintData(depositor, receiver, originToken, amount, erc20Metadata);

        assertNotEq(block.chainid, originChainId);

        assertEq(l2NativeTokenVault.originChainId(assetId), 0);
        assertEq(l2NativeTokenVault.tokenAddress(assetId), address(0));
        assertEq(l2NativeTokenVault.assetId(l2NativeTokenVault.l2TokenAddress(originToken)), bytes32(0));

        // this `mockCall` ensures the branch for legacy tokens is chosen
        vm.mockCall(
            sharedBridgeLegacy,
            abi.encodeCall(IL2SharedBridgeLegacy.l1TokenAddress, (expectedL2TokenAddress)),
            abi.encode(originToken)
        );
        // fails on the following line without this `mockCall`
        // https://github.com/matter-labs/era-contracts/blob/cebfe26a41f3b83039a7d36558bf4e0401b154fc/l1-contracts/contracts/bridge/ntv/NativeTokenVault.sol#L163
        vm.mockCall(
            expectedL2TokenAddress,
            abi.encodeCall(IBridgedStandardToken.bridgeMint, (receiver, amount)),
            ""
        );
        vm.prank(address(l2NativeTokenVault.ASSET_ROUTER()));
        l2NativeTokenVault.bridgeMint(originChainId, assetId, data);

        assertNotEq(l2NativeTokenVault.originChainId(assetId), 0);
        assertEq(l2NativeTokenVault.originChainId(assetId), originChainId);
        assertNotEq(l2NativeTokenVault.tokenAddress(assetId), address(0));
        assertEq(l2NativeTokenVault.tokenAddress(assetId), expectedL2TokenAddress);
        assertEq(l2NativeTokenVault.assetId(expectedL2TokenAddress), assetId);
    }
}
