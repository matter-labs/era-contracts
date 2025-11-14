// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Create2FactoryUtils} from "../Create2FactoryUtils.s.sol";
import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {stdToml} from "forge-std/StdToml.sol";

/// @title DeployGatewayTransactionFilterer
/// @notice This script deploys a GatewayTransactionFilterer behind a TransparentUpgradeableProxy,
/// using Create2 with notify. It takes five parameters:
/// - bridgehub: The address of the Bridgehub contract.
/// - chainAdmin: The admin to be set as the initial owner of the deployed filterer.
/// - chainProxyAdmin: The pre-deployed proxy admin that manages the proxy.
/// - create2FactoryAddress: The configured Create2 factory address.
/// - create2FactorySalt: The salt for the Create2 deployment.
contract DeployGatewayTransactionFilterer is Script, Create2FactoryUtils {
    using stdToml for string;

    function run(
        address bridgehub,
        address chainAdmin,
        address chainProxyAdmin,
        address create2FactoryAddress,
        bytes32 create2FactorySalt
    ) public returns (address proxy) {
        // Initialize and instantiate Create2Factory before any deployment.
        _initCreate2FactoryParams(create2FactoryAddress, create2FactorySalt);
        instantiateCreate2Factory();

        // Query the L1 asset router from the Bridgehub.
        address l1AssetRouter = IL1Bridgehub(bridgehub).assetRouter();

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
    }

    function runWithInputFromFile() public {
        string memory root = vm.projectRoot();
        string memory configPath = string.concat(root, vm.envString("DEPLOY_GATEWAY_TX_FILTERER_INPUT"));
        string memory toml = vm.readFile(configPath);

        address proxy = run(
            toml.readAddress("$.bridgehub_proxy_addr"),
            toml.readAddress("$.chain_admin"),
            toml.readAddress("$.chain_proxy_admin"),
            toml.readAddress("$.create2_factory_addr"),
            toml.readBytes32("$.create2_factory_salt")
        );

        // Save the address of the deployed proxy into an output TOML file.
        string memory outputToml = vm.serializeAddress("root", "gateway_tx_filterer_proxy", proxy);
        string memory outputPath = string.concat(vm.projectRoot(), vm.envString("DEPLOY_GATEWAY_TX_FILTERER_OUTPUT"));
        vm.writeToml(outputToml, outputPath);
    }
}
