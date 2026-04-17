// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {DeployGatewayTransactionFilterer} from "../gateway/DeployGatewayTransactionFilterer.s.sol";
import {ChainInfoFromBridgehub, Utils} from "../utils/Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {AdminFunctions} from "../AdminFunctions.s.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

/// @title DeployAndSetGatewayTransactionFilterer
/// @notice Dev/test helper: deploy GatewayTransactionFilterer and register it on the chain diamond.
///         `convert-to-gateway grant-whitelist` requires a non-zero transaction filterer on the gateway chain.
contract DeployAndSetGatewayTransactionFilterer is Script {
    function run(address _bridgehub, uint256 _chainId) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);
        if (IGetters(chainInfo.diamondProxy).getTransactionFilterer() != address(0)) {
            return;
        }

        vm.startBroadcast();
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(chainInfo.admin);
        vm.stopBroadcast();

        DeployGatewayTransactionFilterer deployer = new DeployGatewayTransactionFilterer();
        address transactionFiltererProxy = deployer.run(_bridgehub, chainInfo.admin, address(proxyAdmin));

        AdminFunctions adminScript = new AdminFunctions();
        adminScript.setTransactionFilterer(_bridgehub, _chainId, transactionFiltererProxy, true);
    }
}
