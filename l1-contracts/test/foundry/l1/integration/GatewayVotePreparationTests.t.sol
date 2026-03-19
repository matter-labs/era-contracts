// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";

import {GatewayVotePreparation} from "deploy-scripts/gateway/GatewayVotePreparation.s.sol";
import {
    GatewayCTMDeployerHelper,
    DeployerCreate2Calldata,
    DeployerAddresses,
    DirectCreate2Calldata
} from "deploy-scripts/gateway/GatewayCTMDeployerHelper.sol";
import {
    DeployedContracts,
    GatewayCTMDeployerConfig
} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IDiamondInit} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

/// @notice Test-friendly subclass of GatewayVotePreparation that exposes the
/// initialization + calculateAddresses path without executing L1->L2 transactions.
contract GatewayVotePreparationForTest is GatewayVotePreparation {
    /// @notice Runs the real config initialization path (TOML parsing + bridgehub introspection)
    /// and then calls GatewayCTMDeployerHelper.calculateAddresses, which is the same call
    /// that deployGatewayCTM() makes internally.
    function initializeAndCalculateAddresses(
        address bridgehubProxy,
        uint256 ctmRepresentativeChainId
    ) public returns (DeployedContracts memory contracts, DirectCreate2Calldata memory directCalldata) {
        string memory root = vm.projectRoot();
        string memory configPath = string.concat(root, vm.envString("GATEWAY_VOTE_PREPARATION_INPUT"));
        string memory permanentValuesPath = string.concat(root, vm.envString("PERMANENT_VALUES_INPUT"));

        initializeConfig(configPath, permanentValuesPath, bridgehubProxy, ctmRepresentativeChainId);
        instantiateCreate2Factory();

        (contracts, , , directCalldata, ) = GatewayCTMDeployerHelper.calculateAddresses(
            bytes32(uint256(1)),
            gatewayCTMDeployerConfig
        );
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
    string internal constant GATEWAY_VOTE_PREPARATION_CONFIG_PATH =
        "/script-out/foundry-gateway-vote-preparation/config.toml";
    string internal constant GATEWAY_VOTE_PREPARATION_OUTPUT_PATH =
        "/script-out/foundry-gateway-vote-preparation/output.toml";

    function setUp() public {
        _deployL1Contracts();
        _deployEra();

        votePreparationScript = new GatewayVotePreparationForTest();

        _writeGatewayVotePreparationConfig();

        vm.setEnv("GATEWAY_VOTE_PREPARATION_INPUT", GATEWAY_VOTE_PREPARATION_CONFIG_PATH);
        vm.setEnv("GATEWAY_VOTE_PREPARATION_OUTPUT", GATEWAY_VOTE_PREPARATION_OUTPUT_PATH);
    }

    /// @notice Calls calculateAddresses through GatewayVotePreparation's real initialization path.
    function test_calculateAddressesViaGatewayVotePreparation() public {
        (DeployedContracts memory contracts, ) = votePreparationScript.initializeAndCalculateAddresses(
            address(addresses.bridgehub),
            eraZKChainId
        );

        // Verify key contract addresses are non-zero
        assertTrue(contracts.stateTransition.chainTypeManagerProxy != address(0), "CTM proxy should be non-zero");
        assertTrue(
            contracts.stateTransition.chainTypeManagerImplementation != address(0),
            "CTM impl should be non-zero"
        );
        assertTrue(
            contracts.stateTransition.validatorTimelockProxy != address(0),
            "ValidatorTimelock proxy should be non-zero"
        );
        assertTrue(contracts.stateTransition.verifiers.verifier != address(0), "Verifier should be non-zero");
        assertTrue(contracts.stateTransition.facets.adminFacet != address(0), "AdminFacet should be non-zero");
        assertTrue(contracts.stateTransition.facets.mailboxFacet != address(0), "MailboxFacet should be non-zero");
        assertTrue(contracts.stateTransition.facets.executorFacet != address(0), "ExecutorFacet should be non-zero");
        assertTrue(contracts.stateTransition.facets.gettersFacet != address(0), "GettersFacet should be non-zero");
        assertTrue(contracts.multicall3 != address(0), "Multicall3 should be non-zero");
        assertTrue(contracts.diamondCutData.length > 0, "Diamond cut data should be non-empty");

        // Verify DA contracts
        assertTrue(contracts.daContracts.rollupDAManager != address(0), "RollupDAManager should be non-zero");
        assertTrue(contracts.daContracts.validiumDAValidator != address(0), "ValidiumDAValidator should be non-zero");

        // Verify determinism: calling again produces identical results
        (DeployedContracts memory contracts2, ) = votePreparationScript.initializeAndCalculateAddresses(
            address(addresses.bridgehub),
            eraZKChainId
        );
        assertEq(
            contracts.stateTransition.chainTypeManagerProxy,
            contracts2.stateTransition.chainTypeManagerProxy,
            "CTM proxy should be deterministic"
        );
    }

    /// @notice Verifies that every facet address in the diamond cut data has a corresponding
    /// non-empty deployment calldata in DirectCreate2Calldata, and that the calculated address
    /// matches the facet address. This catches the bug where _deployDirectContracts skips
    /// deploying MigratorFacet or CommitterFacet.
    function test_allDiamondCutFacetsHaveDeploymentCalldata() public {
        (DeployedContracts memory contracts, DirectCreate2Calldata memory directCalldata) = votePreparationScript
            .initializeAndCalculateAddresses(address(addresses.bridgehub), eraZKChainId);

        // Each direct calldata entry corresponds to a known facet address from calculateAddresses.
        // If any calldata is empty, the corresponding L1->L2 transaction would not be sent.
        assertTrue(directCalldata.adminFacetCalldata.length > 0, "AdminFacet calldata is empty");
        assertTrue(directCalldata.mailboxFacetCalldata.length > 0, "MailboxFacet calldata is empty");
        assertTrue(directCalldata.executorFacetCalldata.length > 0, "ExecutorFacet calldata is empty");
        assertTrue(directCalldata.gettersFacetCalldata.length > 0, "GettersFacet calldata is empty");
        assertTrue(directCalldata.migratorFacetCalldata.length > 0, "MigratorFacet calldata is empty");
        assertTrue(directCalldata.committerFacetCalldata.length > 0, "CommitterFacet calldata is empty");
        assertTrue(directCalldata.diamondInitCalldata.length > 0, "DiamondInit calldata is empty");
        assertTrue(directCalldata.genesisUpgradeCalldata.length > 0, "GenesisUpgrade calldata is empty");
        assertTrue(directCalldata.multicall3Calldata.length > 0, "Multicall3 calldata is empty");

        // Decode the diamond cut data and verify every facet address is one of the calculated addresses
        Diamond.DiamondCutData memory diamondCut = abi.decode(contracts.diamondCutData, (Diamond.DiamondCutData));
        for (uint256 i = 0; i < diamondCut.facetCuts.length; i++) {
            address facet = diamondCut.facetCuts[i].facet;
            assertTrue(facet != address(0), string.concat("Facet at index ", vm.toString(i), " is zero address"));
            assertTrue(
                _isKnownFacetAddress(facet, contracts),
                string.concat(
                    "Facet at index ",
                    vm.toString(i),
                    " (addr ",
                    vm.toString(facet),
                    ") not found in calculated addresses"
                )
            );
        }

        // Verify the initAddress is the calculated DiamondInit
        assertEq(
            diamondCut.initAddress,
            contracts.stateTransition.facets.diamondInit,
            "DiamondInit address mismatch in diamond cut"
        );
    }

    /// @notice Verifies that a DiamondProxy can be deployed with the gateway diamond cut data
    /// including real facet contracts and full DiamondInit.initialize() execution.
    /// We deploy all facets via the deterministic CREATE2 factory (same calldata that
    /// _deployDirectContracts sends as L1->L2 transactions), then build a DiamondProxy.
    /// If any facet deployment was missing (e.g. MigratorFacet or CommitterFacet), the
    /// DiamondProxy constructor reverts with AddressHasNoCode.
    function test_diamondProxyDeployableWithGatewayDiamondCut() public {
        (DeployedContracts memory contracts, DirectCreate2Calldata memory directCalldata) = votePreparationScript
            .initializeAndCalculateAddresses(address(addresses.bridgehub), eraZKChainId);

        GatewayCTMDeployerConfig memory config = votePreparationScript.getDeployerConfig();

        Diamond.DiamondCutData memory diamondCut = abi.decode(contracts.diamondCutData, (Diamond.DiamondCutData));

        // Switch to gateway chain ID so that facet constructors (e.g. MailboxFacet) that
        // check `block.chainid != _l1ChainId` for gateway deployments don't revert.
        vm.chainId(GATEWAY_CHAIN_ID);

        // Etch the deterministic CREATE2 factory and deploy all facets using the exact
        // same calldata that _deployDirectContracts sends via L1->L2 transactions.
        address create2Factory = Utils.DETERMINISTIC_CREATE2_ADDRESS;
        vm.etch(create2Factory, Utils.CREATE2_FACTORY_RUNTIME_BYTECODE);

        _simulateCreate2(create2Factory, directCalldata.adminFacetCalldata, "AdminFacet");
        _simulateCreate2(create2Factory, directCalldata.mailboxFacetCalldata, "MailboxFacet");
        _simulateCreate2(create2Factory, directCalldata.executorFacetCalldata, "ExecutorFacet");
        _simulateCreate2(create2Factory, directCalldata.gettersFacetCalldata, "GettersFacet");
        _simulateCreate2(create2Factory, directCalldata.migratorFacetCalldata, "MigratorFacet");
        _simulateCreate2(create2Factory, directCalldata.committerFacetCalldata, "CommitterFacet");
        _simulateCreate2(create2Factory, directCalldata.diamondInitCalldata, "DiamondInit");
        _simulateCreate2(create2Factory, directCalldata.genesisUpgradeCalldata, "GenesisUpgrade");
        _simulateCreate2(create2Factory, directCalldata.multicall3Calldata, "Multicall3");

        // Mock the CTM calls that DiamondInit.initialize() makes
        address mockCTM = address(0xC7A1);
        vm.mockCall(
            mockCTM,
            abi.encodeWithSelector(IChainTypeManager.PERMISSIONLESS_VALIDATOR.selector),
            abi.encode(address(0))
        );
        vm.mockCall(
            mockCTM,
            abi.encodeWithSelector(IChainTypeManager.protocolVersionVerifier.selector),
            abi.encode(makeAddr("mockVerifier"))
        );

        // Build full initCalldata: selector + InitializeData fields.
        // Use L2_BRIDGEHUB_ADDR as bridgehub so initialize() takes the L2 branch
        // (sets nativeTokenVault/assetTracker from L2 constants, no external calls).
        bytes memory initData1 = bytes.concat(
            IDiamondInit.initialize.selector,
            bytes32(uint256(GATEWAY_CHAIN_ID)), // chainId
            bytes32(uint256(uint160(L2_BRIDGEHUB_ADDR))), // bridgehub
            bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR))), // interopCenter
            bytes32(uint256(uint160(mockCTM))) // chainTypeManager
        );
        bytes memory initData2 = bytes.concat(
            bytes32(config.protocolVersion), // protocolVersion
            bytes32(uint256(uint160(address(0xAD01)))), // admin
            bytes32(uint256(uint160(address(0x1337)))), // validatorTimelock
            keccak256("baseTokenAssetId"), // baseTokenAssetId (non-zero)
            bytes32(uint256(1)), // storedBatchZero
            diamondCut.initCalldata // abi.encode(InitializeDataNewChain)
        );
        diamondCut.initCalldata = bytes.concat(initData1, initData2);

        // Deploy the DiamondProxy with real facets - validates all facets have code AND runs initialize()
        new DiamondProxy(GATEWAY_CHAIN_ID, diamondCut);
    }

    /// @notice Simulates a CREATE2 deployment by calling the deterministic CREATE2 factory.
    function _simulateCreate2(address factory, bytes memory calldataPayload, string memory name) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = factory.call(calldataPayload);
        assertTrue(success, string.concat("CREATE2 deployment failed for ", name));
    }

    /// @notice Checks if an address matches one of the known facet addresses from calculateAddresses.
    function _isKnownFacetAddress(address facet, DeployedContracts memory contracts) internal pure returns (bool) {
        return
            facet == contracts.stateTransition.facets.adminFacet ||
            facet == contracts.stateTransition.facets.mailboxFacet ||
            facet == contracts.stateTransition.facets.executorFacet ||
            facet == contracts.stateTransition.facets.gettersFacet ||
            facet == contracts.stateTransition.facets.migratorFacet ||
            facet == contracts.stateTransition.facets.committerFacet;
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
        vm.createDir(string.concat(vm.projectRoot(), "/script-out/foundry-gateway-vote-preparation"), true);

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
        vm.serializeBytes32(
            "gw_vote_prep",
            "zk_token_asset_id",
            bytes32(0x01000000000000000000000000000000000000000000000000000000000a2a6f)
        );
        vm.serializeUint("gw_vote_prep", "gateway_settlement_fee", 0);
        string memory toml = vm.serializeString("gw_vote_prep", "contracts", contractsToml);

        string memory path = string.concat(vm.projectRoot(), GATEWAY_VOTE_PREPARATION_CONFIG_PATH);
        vm.writeToml(toml, path);
    }

    // Exclude from coverage report
    function test() internal virtual override {}
}
