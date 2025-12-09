// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import { PrividiumTransactionFilterer } from "../contracts/transactionFilterer/PrividiumTransactionFilterer.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import { AdminFunctions } from "./AdminFunctions.s.sol";
import { Utils, ChainInfoFromBridgehub } from "./Utils.sol";

contract DeployPrividiumTransactionFilterer is AdminFunctions {
    function run(address bridgehub, uint256 chainId, bool allowDeposits) {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        PrividiumTransactionFilterer impl = new PrividiumTransactionFilterer(chainInfo.l1AssetRouterProxy);
        address proxy = address(new TransparentUpgradeableProxy(
            address(impl),
            chainInfo.admin,
            abi.encodeCall(PrividiumTransactionFilterer.initialize, (chainInfo.admin))
        ));

        setTransactionFilterer(bridgehub, chainId, proxy, true);
        PrividiumTransactionFilterer filtererProxy = PrividiumTransactionFilterer(proxy);
        filtererProxy.grantWhitelist(chainInfo.admin);
        // TODO: do i want to grant whitelist to others like in gw tx filterer?
        filtererProxy.setDepositsAllowed(allowDeposits);
    }
}
