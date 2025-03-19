import {stdToml} from "forge-std/StdToml.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {GatewayPreparation} from "deploy-scripts/GatewayPreparation.s.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
contract GatewayPreparationForTests is GatewayPreparation {
    using stdToml for string;

    function initializeConfig() internal override {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("L1_OUTPUT"));
        string memory toml = vm.readFile(path);

        config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        config.chainTypeManagerProxy = toml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        config.sharedBridgeProxy = toml.readAddress("$.deployed_addresses.bridges.shared_bridge_proxy_addr");
        config.ctmDeploymentTracker = toml.readAddress(
            "$.deployed_addresses.bridgehub.ctm_deployment_tracker_proxy_addr"
        );
        config.governance = toml.readAddress("$.deployed_addresses.governance_addr");

        path = string.concat(root, vm.envString("GATEWAY_AS_CHAIN_CONFIG"));
        toml = vm.readFile(path);

        config.gatewayChainId = 506; //toml.readUint("$.chain.chain_chain_id");
        // currently there is a single gateway test file.
        console.log("Gateway chain id skipped value = %s", toml.readUint("$.chain.chain_chain_id"));

        path = string.concat(root, vm.envString("GATEWAY_AS_CHAIN_OUTPUT"));
        toml = vm.readFile(path);

        config.gatewayChainAdmin = IZKChain(IBridgehub(config.bridgehub).getZKChain(config.gatewayChainId)).getAdmin();
        // toml.readAddress("$.chain_admin_addr");
        config.gatewayChainProxyAdmin = toml.readAddress("$.chain_proxy_admin_addr");
        config.gatewayAccessControlRestriction = toml.readAddress(
            "$.deployed_addresses.access_control_restriction_addr"
        );
        config.l1NullifierProxy = address(IL1AssetRouter(IBridgehub(config.bridgehub).assetRouter()).L1_NULLIFIER());

        console.log("chain chain id = ", config.gatewayChainId);

        // This value is never checked in the integration tests
        config.gatewayDiamondCutData = hex"";
    }

    function _getL1GasPrice() internal view override returns (uint256) {
        return 10;
    }
}
