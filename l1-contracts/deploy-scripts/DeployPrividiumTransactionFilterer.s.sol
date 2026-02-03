// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {PrividiumTransactionFilterer} from "../contracts/transactionFilterer/PrividiumTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AdminFunctions} from "./AdminFunctions.s.sol";
import {Utils, ChainInfoFromBridgehub} from "./Utils.sol";
import {console} from "forge-std/console.sol";

contract DeployPrividiumTransactionFilterer is AdminFunctions {
    /// @notice Returns the address to use as the deployer/owner for contracts.
    /// @dev This is virtual so test scripts can override it. By default returns tx.origin.
    function getDeployerAddress() public view virtual returns (address) {
        return tx.origin;
    }

    function run(address bridgehub, uint256 chainId, bool allowDeposits) external {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(bridgehub, chainId);

        vm.startBroadcast(getDeployerAddress());
        PrividiumTransactionFilterer impl = new PrividiumTransactionFilterer(chainInfo.l1AssetRouterProxy);
        address proxy = address(
            new TransparentUpgradeableProxy(
                address(impl),
                chainInfo.admin,
                abi.encodeCall(PrividiumTransactionFilterer.initialize, (getDeployerAddress()))
            )
        );
        vm.stopBroadcast();

        super.setTransactionFilterer(bridgehub, chainId, proxy, true);
        PrividiumTransactionFilterer filtererProxy = PrividiumTransactionFilterer(proxy);

        vm.startBroadcast(getDeployerAddress());
        filtererProxy.grantWhitelist(chainInfo.admin);
        filtererProxy.setDepositsAllowed(allowDeposits);
        vm.stopBroadcast();

        console.log("PrividiumTransactionFilterer (proxy) deployed to:", proxy);
    }
}
