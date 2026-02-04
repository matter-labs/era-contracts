// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IDeployGatewayTransactionFilterer} from "contracts/script-interfaces/IDeployGatewayTransactionFilterer.sol";
import {Create2FactoryUtils} from "../utils/deploy/Create2FactoryUtils.s.sol";
import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {stdToml} from "forge-std/StdToml.sol";

/// @title DeployGatewayTransactionFilterer
/// @notice This script deploys a GatewayTransactionFilterer behind a TransparentUpgradeableProxy,
/// using Create2 with notify. It takes three parameters:
/// - bridgehub: The address of the Bridgehub contract.
/// - chainAdmin: The admin to be set as the initial owner of the deployed filterer.
/// - chainProxyAdmin: The pre-deployed proxy admin that manages the proxy.
/// Both create2FactoryAddress and create2FactorySalt are read from permanent-values.toml.
contract DeployGatewayTransactionFilterer is Script, Create2FactoryUtils, IDeployGatewayTransactionFilterer {
    using stdToml for string;

    function initializeConfig(address bridgehub, address chainAdmin, address chainProxyAdmin) internal {
        // Read create2 factory parameters from permanent-values.toml
        (address create2FactoryAddr, bytes32 create2FactorySalt) = getPermanentValues();

        _initCreate2FactoryParams(create2FactoryAddr, create2FactorySalt);
    }

    function run(address bridgehub, address chainAdmin, address chainProxyAdmin) public returns (address proxy) {
        // Initialize config and instantiate Create2Factory before any deployment.
        initializeConfig(bridgehub, chainAdmin, chainProxyAdmin);
        instantiateCreate2Factory();

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

    function runWithInputFromFile() public {
        string memory root = vm.projectRoot();
        string memory configPath = string.concat(root, vm.envString("DEPLOY_GATEWAY_TX_FILTERER_INPUT"));
        string memory toml = vm.readFile(configPath);

        // create2FactoryAddress and create2FactorySalt are both read internally by initializeConfig
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
