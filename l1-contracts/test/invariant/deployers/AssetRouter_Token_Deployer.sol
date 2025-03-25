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
import {L2SharedBridgeLegacy} from "contracts/bridge/L2SharedBridgeLegacy.sol";
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

        tokens = new Token[](6);

        tokens[0] = Token({
            addr: makeAddr("unregistered undeployed-on-L2 non-bridged token"),
            chainid: block.chainid,
            assetDeploymentTrackerAddr: L2_NATIVE_TOKEN_VAULT_ADDR,
            bridged: false
        });

        tokens[1] = Token({
            addr: makeAddr("unregistered undeployed-on-L2 bridged-from-another-L2 token"),
            chainid: anotherL2ChainId,
            assetDeploymentTrackerAddr: L2_NATIVE_TOKEN_VAULT_ADDR,
            bridged: true
        });

        tokens[2] = Token({
            addr: makeAddr("unregistered undeployed-on-L2 bridged-from-L1 token (bridged token)"),
            chainid: l1ChainId,
            assetDeploymentTrackerAddr: address(0), // todo: not sure what address to specify here
            bridged: true
        });

        address token3 = address(new ERC20("TOKEN3", "T3"));
        tokens[3] = Token({
            addr: token3,
            chainid: block.chainid,
            assetDeploymentTrackerAddr: L2_NATIVE_TOKEN_VAULT_ADDR,
            bridged: false
        });
        vm.label(token3, "unregistered deployed-on-L2 non-bridged token (native token)");

        address token4 = makeAddr(
            "registered-with-`L2SharedBridgeLegacy` deployed-on-L2 bridged-from-L1 token (legacy token)"
        );
        tokens[4] = Token({
            addr: token4,
            chainid: l1ChainId,
            assetDeploymentTrackerAddr: address(0), // todo: not sure what address to specify here
            bridged: true
        });
        L2SharedBridgeLegacy(l2SharedBridge).finalizeDeposit({
            _l1Sender: address(1337),
            _l2Receiver: address(1337),
            _l1Token: tokens[4].addr,
            _amount: 0,
            _data: abi.encode(abi.encode("Token"), abi.encode("T"), abi.encode(18))
        });

        tokens[5] = Token({
            addr: l2NativeTokenVault.WETH_TOKEN(),
            chainid: l1ChainId,
            assetDeploymentTrackerAddr: L2_NATIVE_TOKEN_VAULT_ADDR,
            bridged: false
        });
        vm.label(tokens[5].addr, "WETH_TOKEN");
        assertNotEq(tokens[5].addr.code.length, 0, "WETH is not deployed");
    }
}
