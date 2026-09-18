// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IDeployGatewayTransactionFilterer} from "contracts/script-interfaces/IDeployGatewayTransactionFilterer.sol";
import {Create2FactoryUtils} from "../utils/deploy/Create2FactoryUtils.s.sol";

import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {ChainInfoFromBridgehub, Utils} from "../utils/Utils.sol";
import {AdminFunctions} from "../AdminFunctions.s.sol";
import {stdToml} from "forge-std/StdToml.sol";

/// @title DeployGatewayTransactionFilterer
/// @notice This script deploys a GatewayTransactionFilterer behind a TransparentUpgradeableProxy,
/// using Create2 with notify. It takes three parameters:
/// - bridgehub: The address of the Bridgehub contract.
/// - chainAdmin: The admin to be set as the initial owner of the deployed filterer.
/// - chainProxyAdmin: The pre-deployed proxy admin that manages the proxy.
contract DeployGatewayTransactionFilterer is Script, Create2FactoryUtils, IDeployGatewayTransactionFilterer {
    using stdToml for string;

    function run(address bridgehub, address chainAdmin, address chainProxyAdmin) public returns (address proxy) {
        // Query the L1 asset router from the Bridgehub.
        address l1AssetRouter = address(IL1Bridgehub(bridgehub).assetRouter());

        // Deploy the GatewayTransactionFilterer implementation via Create2 with notify.
        // The constructor of GatewayTransactionFilterer expects (bridgehub, l1AssetRouter).
        address implementation = deployViaCreate2AndNotify(
            type(GatewayTransactionFilterer).creationCode,
            abi.encode(bridgehub, l1AssetRouter),
            "GatewayTransactionFilterer",
            "GatewayTransactionFilterer",
            false
        );

        // Prepare the initialization calldata.
        // This initialize function sets the transaction filterer's initial owner to chainAdmin.
        bytes memory initData = abi.encodeCall(GatewayTransactionFilterer.initialize, (chainAdmin));

        // Deploy the TransparentUpgradeableProxy via Create2 with notify.
        // The proxy uses the provided chainProxyAdmin as its admin.
        proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                implementation, // the logic/implementation contract
                chainProxyAdmin, // the admin for the proxy (already deployed)
                initData // initialization calldata to set chainAdmin as owner
            ),
            "TransparentUpgradeableProxy",
            "GatewayTxFiltererProxy",
            false
        );

        saveOutput(proxy);
    }

    /// @notice Dev/test helper: deploy the filterer and register it on the chain diamond.
    ///         `convert-to-gateway grant-whitelist` requires a non-zero transaction filterer on the gateway chain.
    function deployAndSetOnChain(address _bridgehub, uint256 _chainId) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);
        if (IGetters(chainInfo.diamondProxy).getTransactionFilterer() != address(0)) {
            return;
        }

        vm.startBroadcast();
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(chainInfo.admin);
        vm.stopBroadcast();

        address transactionFiltererProxy = run(_bridgehub, chainInfo.admin, address(proxyAdmin));

        AdminFunctions adminScript = new AdminFunctions();
        adminScript.setTransactionFilterer(_bridgehub, _chainId, transactionFiltererProxy, true);
    }

    function runWithInputFromFile() public {
        string memory root = vm.projectRoot();
        string memory configPath = string.concat(root, vm.envString("DEPLOY_GATEWAY_TX_FILTERER_INPUT"));
        string memory toml = vm.readFile(configPath);

        address proxy = run(
            toml.readAddress("$.bridgehub_proxy_addr"),
            toml.readAddress("$.chain_admin"),
            toml.readAddress("$.chain_proxy_admin")
        );
    }

    function saveOutput(address proxy) internal {
        // Save the address of the deployed proxy into an output TOML file.
        string memory outputToml = vm.serializeAddress("root", "gateway_tx_filterer_proxy", proxy);
        string memory outputPath = string.concat(vm.projectRoot(), vm.envString("DEPLOY_GATEWAY_TX_FILTERER_OUTPUT"));
        vm.writeToml(outputToml, outputPath);
    }
}
