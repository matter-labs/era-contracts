// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {PrividiumTransactionFilterer} from "../contracts/transactionFilterer/PrividiumTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AdminFunctions} from "./AdminFunctions.s.sol";
import {Utils, ChainInfoFromBridgehub} from "./Utils.sol";
import {console} from "forge-std/console.sol";

contract DeployPrividiumTransactionFilterer is AdminFunctions {
    function run(address bridgehub, uint256 chainId, bool allowDeposits) external {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(bridgehub, chainId);

        vm.startBroadcast(msg.sender);
        PrividiumTransactionFilterer impl = new PrividiumTransactionFilterer(chainInfo.l1AssetRouterProxy);
        address proxy = address(
            new TransparentUpgradeableProxy(
                address(impl),
                chainInfo.admin,
                abi.encodeCall(PrividiumTransactionFilterer.initialize, (msg.sender))
            )
        );
        vm.stopBroadcast();

        super.setTransactionFilterer(bridgehub, chainId, proxy, true);
        PrividiumTransactionFilterer filtererProxy = PrividiumTransactionFilterer(proxy);

        vm.startBroadcast(msg.sender);
        filtererProxy.grantWhitelist(chainInfo.admin);
        filtererProxy.setDepositsAllowed(allowDeposits);
        vm.stopBroadcast();

        console.log("PrividiumTransactionFilterer (proxy) deployed to:", proxy);
    }
}
