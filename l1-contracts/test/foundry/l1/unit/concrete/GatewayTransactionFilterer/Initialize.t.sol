// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GatewayTransactionFiltererTest} from "./_GatewayTransactionFilterer_Shared.t.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";

contract GatewayTransactionFiltererInitializeTest is GatewayTransactionFiltererTest {
    function test_constructor() public view {
        assertEq(address(transactionFiltererProxy.BRIDGE_HUB()), bridgehub);
        assertEq(transactionFiltererProxy.L1_ASSET_ROUTER(), assetRouter);
    }

    function test_initialize_setsOwner() public view {
        assertEq(transactionFiltererProxy.owner(), owner);
    }

    function test_initialize_revertsOnZeroAddress() public {
        GatewayTransactionFilterer impl = new GatewayTransactionFilterer(IBridgehubBase(bridgehub), assetRouter);

        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(GatewayTransactionFilterer.initialize, address(0))
        );
    }
}
