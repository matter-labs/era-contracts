import {stdToml} from "forge-std/StdToml.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

import {GatewayGovernanceUtils} from "deploy-scripts/gateway/GatewayGovernanceUtils.s.sol";
import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";

import {DeployGatewayTransactionFilterer} from "deploy-scripts/gateway/DeployGatewayTransactionFilterer.s.sol";

import {ChainInfoFromBridgehub, Utils} from "deploy-scripts/Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
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

        _initializeGatewayGovernanceConfig(
            GatewayGovernanceConfig({
                bridgehubProxy: toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr"),
                l1AssetRouterProxy: toml.readAddress("$.deployed_addresses.bridges.shared_bridge_proxy_addr"),
                chainTypeManagerProxy: toml.readAddress(
                    "$.deployed_addresses.state_transition.state_transition_proxy_addr"
                ),
                ctmDeploymentTrackerProxy: toml.readAddress(
                    "$.deployed_addresses.bridgehub.ctm_deployment_tracker_proxy_addr"
                ),
                gatewayChainId: gatewayChainId
            })
        );
    }

    function governanceRegisterGateway() public {
        Call[] memory calls = _getRegisterSettlementLayerCalls();
        Utils.executeCalls(L1Bridgehub(_gatewayGovernanceConfig.bridgehubProxy).owner(), bytes32(0), 0, calls);
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

        AdminFunctions adminScript = new AdminFunctions();
        adminScript.setTransactionFilterer(
            _gatewayGovernanceConfig.bridgehubProxy,
            _gatewayGovernanceConfig.gatewayChainId,
            transactionFiltererProxy,
            true
        );

        address[] memory addressesToGrantWhitelist = new address[](2);
        addressesToGrantWhitelist[0] = _gatewayGovernanceConfig.ctmDeploymentTrackerProxy;
        addressesToGrantWhitelist[1] = L1Bridgehub(_gatewayGovernanceConfig.bridgehubProxy).owner();

        adminScript.grantGatewayWhitelist(
            _gatewayGovernanceConfig.bridgehubProxy,
            _gatewayGovernanceConfig.gatewayChainId,
            addressesToGrantWhitelist,
            true
        );
    }

    function migrateChainToGateway(uint256 migratingChainId) public {
        AdminFunctions adminScript = new AdminFunctions();
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
            PrepareGatewayGovernanceCalls({
                _l1GasPrice: _getL1GasPrice(),
                // Some non-zero address
                _gatewayCTMAddress: address(uint160(1)),
                // Some non-zero address
                _gatewayRollupDAManager: address(uint160(1)),
                // Some non-zero address
                _gatewayValidatorTimelock: address(uint160(1)),
                // Some non-zero address
                _gatewayServerNotifier: address(uint160(1)),
                _refundRecipient: msg.sender,
                _ctmRepresentativeChainId: 0
            })
        );
        Utils.executeCalls(L1Bridgehub(_gatewayGovernanceConfig.bridgehubProxy).owner(), bytes32(0), 0, calls);
    }

    function run() public {
        initializeConfig();
    }

    function _getL1GasPrice() internal view returns (uint256) {
        return 10;
    }
}
