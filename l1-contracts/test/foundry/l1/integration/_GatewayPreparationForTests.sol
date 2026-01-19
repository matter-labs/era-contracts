import {stdToml} from "forge-std/StdToml.sol";
import {Script, console2 as console} from "forge-std/Script.sol";

// import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
// import {IBridgehub} from "contracts/core/bridgehub/IBridgehub.sol";
// import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {GatewayGovernanceUtils} from "deploy-scripts/gateway/GatewayGovernanceUtils.s.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {DeployGatewayTransactionFilterer} from "deploy-scripts/gateway/DeployGatewayTransactionFilterer.s.sol";

import {ChainInfoFromBridgehub, Utils} from "deploy-scripts/utils/Utils.sol";
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
        gatewayChainId = 506; //toml.readUint("$.chain.chain_chain_id");
        // // currently there is a single gateway test file.
        // console.log("Gateway chain id skipped value = %s", toml.readUint("$.chain.chain_chain_id"));

        // Grab config from output of l1 deployment
        path = string.concat(root, vm.envString("CTM_OUTPUT"));
        toml = vm.readFile(path);

        // config.gatewayChainId = 506; //toml.readUint("$.chain.chain_chain_id");
        // currently there is a single gateway test file.
        // console.log("Gateway chain id skipped value = %s", toml.readUint("$.chain.chain_chain_id"));

        // path = string.concat(root, vm.envString("GATEWAY_AS_CHAIN_OUTPUT"));
        // toml = vm.readFile(path);

        // config.gatewayChainAdmin = IZKChain(IBridgehubBase(config.bridgehub).getZKChain(config.gatewayChainId)).getAdmin();
        // // toml.readAddress("$.chain_admin_addr");
        // config.gatewayChainProxyAdmin = toml.readAddress("$.chain_proxy_admin_addr");
        // config.gatewayAccessControlRestriction = toml.readAddress(
        //     "$.deployed_addresses.access_control_restriction_addr"
        // );
        // config.l1NullifierProxy = address(IL1AssetRouter(IBridgehubBase(config.bridgehub).assetRouter()).L1_NULLIFIER());

        // console.log("chain chain id = ", config.gatewayChainId);

        // // This value is never checked in the integration tests
        // config.gatewayDiamondCutData = hex"";
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
        // Note: create2FactoryAddress and create2FactorySalt are read from permanent-values.toml
        address transactionFiltererProxy = deployer.run(
            _gatewayGovernanceConfig.bridgehubProxy,
            chainInfo.admin,
            address(proxyAdmin)
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
