// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {ERC20} from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {L1_TOKEN_ADDRESS} from "../common/Constants.sol";
import {Token} from "../common/Types.sol";

contract AssetRouter_Token_Deployer is Test {
    using stdStorage for StdStorage;

    function _deployTokens() internal returns (Token[] memory tokens) {
        L2NativeTokenVault l2NativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        address l2SharedBridge = L2AssetRouter(L2_ASSET_ROUTER_ADDR).L2_LEGACY_SHARED_BRIDGE();
        uint256 l1ChainId = L2AssetRouter(L2_ASSET_ROUTER_ADDR).L1_CHAIN_ID();
        uint256 anotherL2ChainId = 8080;

        assertEq(l1ChainId, l2NativeTokenVault.L1_CHAIN_ID());
        assertNotEq(l2SharedBridge, address(0));

        // We have the following tokens (see the [README.md](../README.md) for more details):
        // - unregistered undeployed-on-L2 non-bridged token
        // - unregistered undeployed-on-L2 bridged-from-another-L2 token
        // - unregistered undeployed-on-L2 bridged-from-L1 token (bridged token)
        // - unregistered deployed-on-L2 non-bridged token (native token)
        // - registered-with-`L2SharedBridgeLegacy` deployed-on-L2 bridged-from-L1 token (legacy token)
        // - base token
        // - WETH

        tokens = new Token[](5);

        tokens[0] = Token({addr: makeAddr("unregistered undeployed-on-L2 non-bridged token"), chainid: block.chainid, bridged: false});

        tokens[1] = Token({addr: makeAddr("unregistered undeployed-on-L2 bridged-from-another-L2 token"), chainid: anotherL2ChainId, bridged: true});

        tokens[2] = Token({addr: makeAddr("unregistered undeployed-on-L2 bridged-from-L1 token (bridged token)"), chainid: l1ChainId, bridged: true});

        address token3 = address(new ERC20("TOKEN3", "T3"));
        tokens[3] = Token({addr: token3, chainid: block.chainid, bridged: false});
        vm.label(token3, "unregistered deployed-on-L2 non-bridged token (native token)");

        address token4 = makeAddr("registered-with-`L2SharedBridgeLegacy` deployed-on-L2 bridged-from-L1 token (legacy token)");
        tokens[4] = Token({addr: token4, chainid: l1ChainId, bridged: true});

        UpgradeableBeacon beacon = IL2SharedBridgeLegacy(l2SharedBridge).l2TokenBeacon();
        bytes32 salt = bytes32(uint256(uint160(token4)));
        BeaconProxy proxy = new BeaconProxy{salt: salt}(address(beacon), "");

        address l2Token = IL2SharedBridgeLegacy(l2SharedBridge).l2TokenAddress(token4);
        vm.label(l2Token, "registered-with-`L2SharedBridgeLegacy` deployed-on-L2 bridged-from-L1 token (legacy token) - L2 address");
        vm.etch(l2Token, address(proxy).code);
        // slot - https://github.com/Openzeppelin/openzeppelin-contracts/blob/dc44c9f1a4c3b10af99492eed84f83ed244203f6/contracts/proxy/ERC1967/ERC1967Upgrade.sol#L123
        vm.store(
            l2Token,
            0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50,
            bytes32(uint256(uint160(address(beacon))))
        );

        stdstore.target(l2SharedBridge).sig("l1TokenAddress(address)").with_key(l2Token).checked_write(token4);

        bytes32 assetId = DataEncoding.encodeNTVAssetId(l1ChainId, token4);
        vm.prank(address(l2NativeTokenVault));
        BridgedStandardERC20(l2Token).bridgeInitialize(
            assetId,
            token4,
            abi.encode(abi.encode("Token"), abi.encode("T"), abi.encode(18))
        );

        // asserting because once `L2NativeTokenVaultDev`'s and `L2NativeTokenVault`'s implementations
        // of `calculateCreate2TokenAddress` returned different addresses
        assertEq(
            l2Token,
            l2NativeTokenVault.calculateCreate2TokenAddress(l1ChainId, token4),
            "SharedBridge and L2NativeTokenVault address calculation differs"
        );
        assertEq(l2NativeTokenVault.originChainId(assetId), 0);
    }
}
