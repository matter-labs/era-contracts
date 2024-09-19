import {stdToml} from "forge-std/StdToml.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {GatewayPreparation} from "deploy-scripts/GatewayPreparation.s.sol";

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
        config.governance = toml.readAddress(
            "$.deployed_addresses.governance_addr"
        );

        path = string.concat(root, vm.envString("GATEWAY_CONFIG"));
        toml = vm.readFile(path);

        config.chainChainId = toml.readUint("$.chain.chain_chain_id");

        console.log("chain chain id = ", config.chainChainId);


        // This value is never checked in the integration tests
        // TODO: maybe use a more realistic value
        config.gatewayDiamondCutData = hex"";
    }
    
    function _getL1GasPrice() internal view override returns (uint256) {
        return 10;
    }
}

