// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {SystemContractsArgs} from "../../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";

import {L2Utils} from "../../integration/L2Utils.sol";
import {L2TransactionRequestTwoBridgesOuter, IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

contract InteropTest is Test {
    IBridgehub internal bridgehub;
    function setUp() public {
        bridgehub = IBridgehub(L2_BRIDGEHUB_ADDR);
        L2Utils.initSystemContracts(
            SystemContractsArgs({
                l1ChainId: 1,
                eraChainId: 2,
                l1AssetRouter: address(1),
                legacySharedBridge: address(2),
                l2TokenBeacon: address(3),
                l2TokenProxyBytecodeHash: bytes32(uint256(4)),
                aliasedOwner: address(5),
                contractsDeployedAlready: false,
                l1CtmDeployer: address(6)
            })
        );
    }

    function test_interop() public {
        uint256 mintValue = 100;
        uint256 secondBridgeValue = 3;
        L2TransactionRequestTwoBridgesOuter memory request = L2TransactionRequestTwoBridgesOuter({
            chainId: 1,
            mintValue: mintValue,
            l2Value: 1,
            l2GasLimit: 1,
            l2GasPerPubdataByteLimit: 1,
            refundRecipient: address(1),
            secondBridgeAddress: L2_ASSET_ROUTER_ADDR,
            secondBridgeValue: secondBridgeValue,
            secondBridgeCalldata: new bytes(0)
        });
        bridgehub.requestL2TransactionTwoBridges{value: mintValue + secondBridgeValue}(request);
    }
}
