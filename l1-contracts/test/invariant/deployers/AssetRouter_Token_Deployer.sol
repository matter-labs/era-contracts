// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";

contract AssetRouter_Token_Deployer is Test {
    using stdStorage for StdStorage;

    function _deployTokens() internal returns (address[] memory l1Tokens) {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        address l2SharedBridge = L2AssetRouter(L2_ASSET_ROUTER_ADDR).L2_LEGACY_SHARED_BRIDGE();
        uint256 l1ChainId = L2AssetRouter(L2_ASSET_ROUTER_ADDR).L1_CHAIN_ID();

        assertEq(l1ChainId, l2NativeTokenVault.L1_CHAIN_ID());
        assertNotEq(l2SharedBridge, address(0));

        // Each token has one of each 5 attributes:
        // - Legacy/non-legacy token (legacy deployed by the SharedBridge and is registered in L2SharedBridgeLegacy)
        // - Registered/unregistered token (registered in L2NativeTokenVault)
        // - Deployed/undeployed token
        // - Native/bridged token
        // - Base/non-base token
        l1Tokens = new address[](1);
        // legacy, unregistered, deployed, bridged, non-base
        address l1Token = makeAddr("legacyUnregisteredBridged L1 token");
        l1Tokens[0] = l1Token;

        UpgradeableBeacon beacon = IL2SharedBridgeLegacy(l2SharedBridge).l2TokenBeacon();
        bytes32 salt = bytes32(uint256(uint160(l1Token)));
        BeaconProxy proxy = new BeaconProxy{salt: salt}(address(beacon), "");

        address l2Token = IL2SharedBridgeLegacy(l2SharedBridge).l2TokenAddress(l1Token);
        vm.label(l2Token, "legacyUnregisteredBridged L2 token");
        vm.etch(l2Token, address(proxy).code);
        // slot - https://github.com/Openzeppelin/openzeppelin-contracts/blob/dc44c9f1a4c3b10af99492eed84f83ed244203f6/contracts/proxy/ERC1967/ERC1967Upgrade.sol#L123
        vm.store(l2Token, 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50, bytes32(uint256(uint160(address(beacon)))));

        stdstore
            .target(l2SharedBridge)
            .sig("l1TokenAddress(address)")
            .with_key(l2Token)
            .checked_write(l1Token);

        bytes32 assetId = DataEncoding.encodeNTVAssetId(l1ChainId, l1Token);
        vm.prank(address(l2NativeTokenVault));
        BridgedStandardERC20(l2Token).bridgeInitialize(assetId, l1Token, abi.encode(abi.encode("Token"), abi.encode("T"), abi.encode(18)));

        // asserting because once `L2NativeTokenVaultDev`'s and `L2NativeTokenVault`'s implementations
        // of `calculateCreate2TokenAddress` returned different addresses
        assertEq(l2Token, l2NativeTokenVault.calculateCreate2TokenAddress(l1ChainId, l1Token), "SharedBridge and L2NativeTokenVault address calculation differs");

        assertEq(l2NativeTokenVault.originChainId(assetId), 0);
    }
}