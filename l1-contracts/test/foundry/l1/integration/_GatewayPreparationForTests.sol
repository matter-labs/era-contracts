import {stdToml} from "forge-std/StdToml.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

// import {GatewayPreparation} from "deploy-scripts/GatewayPreparation.s.sol";

import { GatewayGovernanceUtils } from "deploy-scripts/GatewayGovernanceUtils.s.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";

import {DeployGatewayTransactionFilterer} from "deploy-scripts/DeployGatewayTransactionFilterer.s.sol";

import {Utils, ChainInfoFromBridgehub} from "deploy-scripts/Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {AcceptAdmin} from "deploy-scripts/AcceptAdmin.s.sol";
import {Call} from "contracts/governance/Common.sol";


contract GatewayPreparationForTests is Script, GatewayGovernanceUtils {
    using stdToml for string;

    function initializeConfig() internal {
        string memory root = vm.projectRoot();

        string memory path = string.concat(root, vm.envString("GATEWAY_AS_CHAIN_CONFIG"));
        string memory toml = vm.readFile(path);

        uint256 gatewayChainId = toml.readUint("$.chain.chain_chain_id");

        // Grab config from output of l1 deployment
        path = string.concat(root, vm.envString("L1_OUTPUT"));
        toml = vm.readFile(path);

        // console.log(toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr"));
        // console.log(toml.readAddress("$.deployed_addresses.bridges.shared_bridge_proxy_addr"));

        _initializeGatewayGovernanceConfig(GatewayGovernanceConfig({
            bridgehubProxy: toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr"),
            l1AssetRouterProxy: toml.readAddress("$.deployed_addresses.bridges.shared_bridge_proxy_addr"),
            chainTypeManagerProxy: toml.readAddress(
              "$.deployed_addresses.state_transition.state_transition_proxy_addr"
            ),
            ctmDeploymentTrackerProxy: toml.readAddress("$.deployed_addresses.bridgehub.ctm_deployment_tracker_proxy_addr"),
            gatewayChainId: gatewayChainId
        }));
    }

    function governanceRegisterGateway() public {
        Call[] memory calls = _getRegisterSettlementLayerCalls();
        Utils.executeCalls(Bridgehub(_gatewayGovernanceConfig.bridgehubProxy).owner(), bytes32(0), 0, calls);

        // vm.startBroadcast();
        // for(uint256 i = 0; i < calls.length; i++) {
        //     (bool success, ) = calls[i].target.call{value: calls[i].value}(calls[i].data);
        //     require(success, "Call unsuccessfull");
        // }
        // vm.stopBroadcast();
    }

    function deployAndSetGatewayTransactionFilterer() public {
        DeployGatewayTransactionFilterer deployer = new DeployGatewayTransactionFilterer();

        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(
            _gatewayGovernanceConfig.bridgehubProxy,
            _gatewayGovernanceConfig.gatewayChainId
        );

        vm.startBroadcast();
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(chainInfo.admin);
        vm.stopBroadcast();

        // The values provided here are dummy, but allow the test to be run smoothly
        address transactionFiltererProxy = deployer.run(
            _gatewayGovernanceConfig.bridgehubProxy,
            chainInfo.admin,
            address(proxyAdmin),
            // Unknown
            address(0),
            bytes32(0)
        );

        AcceptAdmin adminScript = new AcceptAdmin();
        adminScript.setTransactionFilterer(_gatewayGovernanceConfig.bridgehubProxy, _gatewayGovernanceConfig.gatewayChainId, transactionFiltererProxy, true);
    }

    function migrateChainToGateway(uint256 migratingChainId) public {
        AcceptAdmin adminScript = new AcceptAdmin();
        adminScript.migrateChainToGateway(
            _gatewayGovernanceConfig.bridgehubProxy,
            _getL1GasPrice(),
            migratingChainId,
            _gatewayGovernanceConfig.gatewayChainId,
            // Not checked in the test
            hex"",
            msg.sender,
            true
        );
    }

    function fullGatewayRegistration() public {
        Call[] memory calls = _prepareGatewayGovernanceCalls(
            _getL1GasPrice(),
            // Some non-zero address
            address(uint160(1)),
            msg.sender
        );
        Utils.executeCalls(Bridgehub(_gatewayGovernanceConfig.bridgehubProxy).owner(), bytes32(0), 0, calls);
    }

    function run() public {
        initializeConfig();
    }

    function _getL1GasPrice() internal view returns (uint256) {
        return 10;
    }
}
