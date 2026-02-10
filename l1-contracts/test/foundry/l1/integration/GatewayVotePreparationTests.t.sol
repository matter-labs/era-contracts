// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {GatewayVotePreparation} from "deploy-scripts/gateway/GatewayVotePreparation.s.sol";
import {GatewayCTMDeployerHelper, DeployerCreate2Calldata, DeployerAddresses, DirectCreate2Calldata} from "deploy-scripts/gateway/GatewayCTMDeployerHelper.sol";
import {DeployedContracts, GatewayCTMDeployerConfig} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";

/// @notice Test-friendly subclass of GatewayVotePreparation that exposes the
/// initialization + calculateAddresses path without executing L1→L2 transactions.
contract GatewayVotePreparationForTest is GatewayVotePreparation {
    /// @notice Runs the real config initialization path (TOML parsing + bridgehub introspection)
    /// and then calls GatewayCTMDeployerHelper.calculateAddresses, which is the same call
    /// that deployGatewayCTM() makes internally.
    function initializeAndCalculateAddresses(
        address bridgehubProxy,
        uint256 ctmRepresentativeChainId
    ) public returns (DeployedContracts memory contracts) {
        string memory root = vm.projectRoot();
        string memory configPath = string.concat(root, vm.envString("GATEWAY_VOTE_PREPARATION_INPUT"));
        string memory permanentValuesPath = string.concat(root, vm.envString("PERMANENT_VALUES_INPUT"));

        initializeConfig(configPath, permanentValuesPath, bridgehubProxy, ctmRepresentativeChainId);
        instantiateCreate2Factory();

        (contracts, , , , ) = GatewayCTMDeployerHelper.calculateAddresses(bytes32(0), gatewayCTMDeployerConfig);
    }

    /// @notice Exposes the populated config for test assertions.
    function getDeployerConfig() public view returns (GatewayCTMDeployerConfig memory) {
        return gatewayCTMDeployerConfig;
    }
}

/// @title GatewayVotePreparationTests
/// @notice Integration tests for GatewayVotePreparation script.
/// @dev Deploys the full L1 environment (bridgehub, CTM, era chain), then calls through
/// GatewayVotePreparation's initialization path and exercises calculateAddresses.
contract GatewayVotePreparationTests is ZKChainDeployer {
    GatewayVotePreparationForTest votePreparationScript;

    uint256 constant GATEWAY_CHAIN_ID = 506;

    function setUp() public {
        _deployL1Contracts();
        _deployEra();

        votePreparationScript = new GatewayVotePreparationForTest();

        _writeGatewayVotePreparationConfig();

        vm.setEnv(
            "GATEWAY_VOTE_PREPARATION_INPUT",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-gateway-vote-preparation.toml"
        );
        vm.setEnv(
            "GATEWAY_VOTE_PREPARATION_OUTPUT",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-gateway-vote-preparation.toml"
        );
    }

    /// @notice Calls calculateAddresses through GatewayVotePreparation's real initialization path.
    function test_calculateAddressesViaGatewayVotePreparation() public {
        DeployedContracts memory contracts = votePreparationScript.initializeAndCalculateAddresses(
            address(addresses.bridgehub),
            eraZKChainId
        );

        // Verify key contract addresses are non-zero
        assertTrue(
            contracts.stateTransition.chainTypeManagerProxy != address(0),
            "CTM proxy should be non-zero"
        );
        assertTrue(
            contracts.stateTransition.chainTypeManagerImplementation != address(0),
            "CTM impl should be non-zero"
        );
        assertTrue(
            contracts.stateTransition.validatorTimelockProxy != address(0),
            "ValidatorTimelock proxy should be non-zero"
        );
        assertTrue(
            contracts.stateTransition.verifiers.verifier != address(0),
            "Verifier should be non-zero"
        );
        assertTrue(
            contracts.stateTransition.facets.adminFacet != address(0),
            "AdminFacet should be non-zero"
        );
        assertTrue(
            contracts.stateTransition.facets.mailboxFacet != address(0),
            "MailboxFacet should be non-zero"
        );
        assertTrue(
            contracts.stateTransition.facets.executorFacet != address(0),
            "ExecutorFacet should be non-zero"
        );
        assertTrue(
            contracts.stateTransition.facets.gettersFacet != address(0),
            "GettersFacet should be non-zero"
        );
        assertTrue(contracts.multicall3 != address(0), "Multicall3 should be non-zero");
        assertTrue(contracts.diamondCutData.length > 0, "Diamond cut data should be non-empty");

        // Verify DA contracts
        assertTrue(
            contracts.daContracts.rollupDAManager != address(0),
            "RollupDAManager should be non-zero"
        );
        assertTrue(
            contracts.daContracts.validiumDAValidator != address(0),
            "ValidiumDAValidator should be non-zero"
        );

        // Verify determinism: calling again produces identical results
        DeployedContracts memory contracts2 = votePreparationScript.initializeAndCalculateAddresses(
            address(addresses.bridgehub),
            eraZKChainId
        );
        assertEq(
            contracts.stateTransition.chainTypeManagerProxy,
            contracts2.stateTransition.chainTypeManagerProxy,
            "CTM proxy should be deterministic"
        );
    }

    /// @notice Verifies the deployer config was populated correctly from the live bridgehub.
    function test_configPopulatedFromBridgehub() public {
        votePreparationScript.initializeAndCalculateAddresses(address(addresses.bridgehub), eraZKChainId);

        GatewayCTMDeployerConfig memory config = votePreparationScript.getDeployerConfig();

        assertTrue(config.aliasedGovernanceAddress != address(0), "Aliased governance should be set");
        assertTrue(config.l1ChainId != 0, "L1 chain ID should be set");
        assertTrue(config.adminSelectors.length > 0, "Admin selectors should be populated");
        assertTrue(config.executorSelectors.length > 0, "Executor selectors should be populated");
        assertTrue(config.mailboxSelectors.length > 0, "Mailbox selectors should be populated");
        assertTrue(config.gettersSelectors.length > 0, "Getters selectors should be populated");
        assertTrue(config.genesisRoot != bytes32(0), "Genesis root should be set");
        assertTrue(config.protocolVersion != 0, "Protocol version should be set");
        assertTrue(config.isZKsyncOS, "Config should be in ZKsyncOS mode");
    }

    function _writeGatewayVotePreparationConfig() internal {
        vm.serializeAddress("contracts", "governance_security_council_address", address(0));
        vm.serializeUint("contracts", "governance_min_delay", 0);
        string memory contractsToml = vm.serializeUint("contracts", "validator_timelock_execution_delay", 0);

        vm.serializeAddress("gw_vote_prep", "owner_address", addresses.bridgehub.owner());
        vm.serializeBool("gw_vote_prep", "testnet_verifier", true);
        vm.serializeBool("gw_vote_prep", "support_l2_legacy_shared_bridge_test", false);
        vm.serializeBool("gw_vote_prep", "is_zk_sync_os", true);
        vm.serializeAddress("gw_vote_prep", "refund_recipient", address(0xBEEF));
        vm.serializeUint("gw_vote_prep", "gateway_chain_id", GATEWAY_CHAIN_ID);
        vm.serializeBytes("gw_vote_prep", "force_deployments_data", hex"00");
        string memory toml = vm.serializeString("gw_vote_prep", "contracts", contractsToml);

        string memory path = string.concat(
            vm.projectRoot(),
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-gateway-vote-preparation.toml"
        );
        vm.writeToml(toml, path);
    }

    // Exclude from coverage report
    function test() internal virtual override {}
}
