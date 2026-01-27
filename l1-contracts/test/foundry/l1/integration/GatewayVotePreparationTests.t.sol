// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {GatewayDeployer} from "./_SharedGatewayDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

import {GatewayGovernanceUtils} from "deploy-scripts/gateway/GatewayGovernanceUtils.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION, NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";

/// @title GatewayGovernanceUtilsForTest
/// @notice Test helper contract that exposes GatewayGovernanceUtils internal functions
contract GatewayGovernanceUtilsForTest is GatewayGovernanceUtils {
    /// @notice Initializes the gateway governance config (exposed for testing)
    function initializeGatewayGovernanceConfigPublic(GatewayGovernanceConfig memory config) public {
        _initializeGatewayGovernanceConfig(config);
    }

    /// @notice Gets the register settlement layer calls (exposed for testing)
    function getRegisterSettlementLayerCallsPublic() public view returns (Call[] memory) {
        return _getRegisterSettlementLayerCalls();
    }

    /// @notice Prepares gateway governance calls (exposed for testing)
    function prepareGatewayGovernanceCallsPublic(
        PrepareGatewayGovernanceCalls memory prepareGWGovCallsStruct
    ) public returns (Call[] memory) {
        return _prepareGatewayGovernanceCalls(prepareGWGovCallsStruct);
    }

    /// @notice Returns the current gateway governance config
    function getGatewayGovernanceConfig() public view returns (GatewayGovernanceConfig memory) {
        return _gatewayGovernanceConfig;
    }

    /// @notice Empty run function required by Script inheritance
    function run() public {}
}

/// @title GatewayVotePreparationTests
/// @notice Integration tests for GatewayVotePreparation functionality
/// @dev Tests the GatewayGovernanceUtils functions which are core to GatewayVotePreparation
contract GatewayVotePreparationTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker, GatewayDeployer {
    uint256 constant TEST_USERS_COUNT = 5;
    address[] public users;

    uint256 gatewayChainId = 506;
    IZKChain gatewayChain;

    GatewayGovernanceUtilsForTest public gatewayGovernanceUtils;

    function _generateUserAddresses() internal {
        require(users.length == 0, "Addresses already generated");
        for (uint256 i = 0; i < TEST_USERS_COUNT; i++) {
            address newAddress = makeAddr(string(abi.encode("user", i)));
            users.push(newAddress);
        }
    }

    function setUp() public {
        _generateUserAddresses();

        _deployL1Contracts();

        // Deploy the gateway chain
        _deployZKChain(ETH_TOKEN_ADDRESS, gatewayChainId);
        acceptPendingAdmin(gatewayChainId);

        _initializeGatewayScript();

        vm.deal(ecosystemConfig.ownerAddress, 100 ether);
        gatewayChain = IZKChain(IL1Bridgehub(addresses.bridgehub).getZKChain(gatewayChainId));
        vm.deal(gatewayChain.getAdmin(), 100 ether);

        // Create the test helper contract
        gatewayGovernanceUtils = new GatewayGovernanceUtilsForTest();
    }

    /// @notice Test that GatewayGovernanceConfig can be initialized correctly
    function test_initializeGatewayGovernanceConfig() public {
        GatewayGovernanceUtils.GatewayGovernanceConfig memory config = GatewayGovernanceUtils.GatewayGovernanceConfig({
            bridgehubProxy: address(addresses.bridgehub),
            l1AssetRouterProxy: address(addresses.sharedBridge),
            chainTypeManagerProxy: address(addresses.chainTypeManager),
            ctmDeploymentTrackerProxy: address(addresses.ctmDeploymentTracker),
            gatewayChainId: gatewayChainId
        });

        gatewayGovernanceUtils.initializeGatewayGovernanceConfigPublic(config);

        GatewayGovernanceUtils.GatewayGovernanceConfig memory storedConfig = gatewayGovernanceUtils.getGatewayGovernanceConfig();

        assertEq(storedConfig.bridgehubProxy, address(addresses.bridgehub), "Bridgehub proxy mismatch");
        assertEq(storedConfig.l1AssetRouterProxy, address(addresses.sharedBridge), "L1AssetRouter proxy mismatch");
        assertEq(storedConfig.chainTypeManagerProxy, address(addresses.chainTypeManager), "CTM proxy mismatch");
        assertEq(storedConfig.ctmDeploymentTrackerProxy, address(addresses.ctmDeploymentTracker), "CTMDeploymentTracker proxy mismatch");
        assertEq(storedConfig.gatewayChainId, gatewayChainId, "Gateway chain ID mismatch");
    }

    /// @notice Test that register settlement layer calls are generated correctly
    function test_getRegisterSettlementLayerCalls() public {
        _initializeTestGatewayGovernanceConfig();

        Call[] memory calls = gatewayGovernanceUtils.getRegisterSettlementLayerCallsPublic();

        assertEq(calls.length, 1, "Should have exactly 1 call");
        assertEq(calls[0].target, address(addresses.bridgehub), "Call target should be bridgehub");
        assertEq(calls[0].value, 0, "Call value should be 0");

        // Verify the call data is encoding registerSettlementLayer correctly
        bytes memory expectedData = abi.encodeCall(IL1Bridgehub.registerSettlementLayer, (gatewayChainId, true));
        assertEq(calls[0].data, expectedData, "Call data mismatch");
    }

    /// @notice Test that register settlement layer calls execute correctly
    function test_executeRegisterSettlementLayerCalls() public {
        _initializeTestGatewayGovernanceConfig();

        // Verify gateway is not whitelisted before
        bool isWhitelistedBefore = addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId);
        assertFalse(isWhitelistedBefore, "Gateway should not be whitelisted initially");

        Call[] memory calls = gatewayGovernanceUtils.getRegisterSettlementLayerCallsPublic();

        // Execute the call as the bridgehub owner
        vm.prank(addresses.bridgehub.owner());
        (bool success, ) = calls[0].target.call{value: calls[0].value}(calls[0].data);
        assertTrue(success, "Call should succeed");

        // Verify gateway is now whitelisted
        bool isWhitelistedAfter = addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId);
        assertTrue(isWhitelistedAfter, "Gateway should be whitelisted after call");
    }

    /// @notice Test prepareGatewayGovernanceCalls returns valid calls array
    function test_prepareGatewayGovernanceCalls_returnsValidCalls() public {
        _initializeTestGatewayGovernanceConfig();

        // Use dummy addresses for gateway-specific contracts
        address dummyGatewayCTM = makeAddr("gatewayCTM");
        address dummyRollupDAManager = makeAddr("rollupDAManager");
        address dummyValidatorTimelock = makeAddr("validatorTimelock");
        address dummyServerNotifier = makeAddr("serverNotifier");
        address refundRecipient = users[0];

        GatewayGovernanceUtils.PrepareGatewayGovernanceCalls memory prepareStruct = GatewayGovernanceUtils.PrepareGatewayGovernanceCalls({
            _l1GasPrice: 10 gwei,
            _gatewayCTMAddress: dummyGatewayCTM,
            _gatewayRollupDAManager: dummyRollupDAManager,
            _gatewayValidatorTimelock: dummyValidatorTimelock,
            _gatewayServerNotifier: dummyServerNotifier,
            _refundRecipient: refundRecipient,
            _ctmRepresentativeChainId: 0
        });

        Call[] memory calls = gatewayGovernanceUtils.prepareGatewayGovernanceCallsPublic(prepareStruct);

        // Should have multiple calls for various governance actions
        assertTrue(calls.length > 0, "Should generate governance calls");

        // Verify all calls have valid targets (non-zero addresses)
        for (uint256 i = 0; i < calls.length; i++) {
            assertTrue(calls[i].target != address(0), "Call target should not be zero address");
        }
    }

    /// @notice Test prepareGatewayGovernanceCalls with ctmRepresentativeChainId equal to gatewayChainId
    function test_prepareGatewayGovernanceCalls_withMatchingCtmRepresentativeChainId() public {
        _initializeTestGatewayGovernanceConfig();

        address dummyGatewayCTM = makeAddr("gatewayCTM");
        address dummyRollupDAManager = makeAddr("rollupDAManager");
        address dummyValidatorTimelock = makeAddr("validatorTimelock");
        address dummyServerNotifier = makeAddr("serverNotifier");
        address refundRecipient = users[0];

        // When ctmRepresentativeChainId equals gatewayChainId, it should include register settlement layer calls
        GatewayGovernanceUtils.PrepareGatewayGovernanceCalls memory prepareStruct = GatewayGovernanceUtils.PrepareGatewayGovernanceCalls({
            _l1GasPrice: 10 gwei,
            _gatewayCTMAddress: dummyGatewayCTM,
            _gatewayRollupDAManager: dummyRollupDAManager,
            _gatewayValidatorTimelock: dummyValidatorTimelock,
            _gatewayServerNotifier: dummyServerNotifier,
            _refundRecipient: refundRecipient,
            _ctmRepresentativeChainId: gatewayChainId // Same as gateway chain ID
        });

        Call[] memory calls = gatewayGovernanceUtils.prepareGatewayGovernanceCallsPublic(prepareStruct);

        assertTrue(calls.length > 0, "Should generate governance calls");

        // First call should be to register settlement layer when ctmRepresentativeChainId == gatewayChainId
        bytes memory expectedFirstCallData = abi.encodeCall(IL1Bridgehub.registerSettlementLayer, (gatewayChainId, true));
        assertEq(calls[0].target, address(addresses.bridgehub), "First call should target bridgehub");
        assertEq(calls[0].data, expectedFirstCallData, "First call should register settlement layer");
    }

    /// @notice Test that governance calls include asset deployment tracker setup
    function test_prepareGatewayGovernanceCalls_includesAssetDeploymentTrackerSetup() public {
        _initializeTestGatewayGovernanceConfig();

        address dummyGatewayCTM = makeAddr("gatewayCTM");
        address dummyRollupDAManager = makeAddr("rollupDAManager");
        address dummyValidatorTimelock = makeAddr("validatorTimelock");
        address dummyServerNotifier = makeAddr("serverNotifier");
        address refundRecipient = users[0];

        GatewayGovernanceUtils.PrepareGatewayGovernanceCalls memory prepareStruct = GatewayGovernanceUtils.PrepareGatewayGovernanceCalls({
            _l1GasPrice: 10 gwei,
            _gatewayCTMAddress: dummyGatewayCTM,
            _gatewayRollupDAManager: dummyRollupDAManager,
            _gatewayValidatorTimelock: dummyValidatorTimelock,
            _gatewayServerNotifier: dummyServerNotifier,
            _refundRecipient: refundRecipient,
            _ctmRepresentativeChainId: 0
        });

        Call[] memory calls = gatewayGovernanceUtils.prepareGatewayGovernanceCallsPublic(prepareStruct);

        // Find the call that sets up the asset deployment tracker
        bool foundAssetRouterCall = false;
        bool foundCTMDeploymentTrackerCall = false;

        for (uint256 i = 0; i < calls.length; i++) {
            if (calls[i].target == address(addresses.sharedBridge)) {
                // Check if this is the setAssetDeploymentTracker call
                bytes4 selector = bytes4(calls[i].data);
                if (selector == L1AssetRouter.setAssetDeploymentTracker.selector) {
                    foundAssetRouterCall = true;
                }
            }
            if (calls[i].target == address(addresses.ctmDeploymentTracker)) {
                // Check if this is the registerCTMAssetOnL1 call
                bytes4 selector = bytes4(calls[i].data);
                if (selector == ICTMDeploymentTracker.registerCTMAssetOnL1.selector) {
                    foundCTMDeploymentTrackerCall = true;
                }
            }
        }

        assertTrue(foundAssetRouterCall, "Should include setAssetDeploymentTracker call");
        assertTrue(foundCTMDeploymentTrackerCall, "Should include registerCTMAssetOnL1 call");
    }

    /// @notice Test config values are preserved across multiple initializations
    function test_configPersistence() public {
        GatewayGovernanceUtils.GatewayGovernanceConfig memory config1 = GatewayGovernanceUtils.GatewayGovernanceConfig({
            bridgehubProxy: address(addresses.bridgehub),
            l1AssetRouterProxy: address(addresses.sharedBridge),
            chainTypeManagerProxy: address(addresses.chainTypeManager),
            ctmDeploymentTrackerProxy: address(addresses.ctmDeploymentTracker),
            gatewayChainId: gatewayChainId
        });

        gatewayGovernanceUtils.initializeGatewayGovernanceConfigPublic(config1);

        // Get calls with first config
        Call[] memory calls1 = gatewayGovernanceUtils.getRegisterSettlementLayerCallsPublic();

        // Re-initialize with different gateway chain ID
        uint256 newGatewayChainId = 999;
        GatewayGovernanceUtils.GatewayGovernanceConfig memory config2 = GatewayGovernanceUtils.GatewayGovernanceConfig({
            bridgehubProxy: address(addresses.bridgehub),
            l1AssetRouterProxy: address(addresses.sharedBridge),
            chainTypeManagerProxy: address(addresses.chainTypeManager),
            ctmDeploymentTrackerProxy: address(addresses.ctmDeploymentTracker),
            gatewayChainId: newGatewayChainId
        });

        gatewayGovernanceUtils.initializeGatewayGovernanceConfigPublic(config2);

        // Get calls with second config
        Call[] memory calls2 = gatewayGovernanceUtils.getRegisterSettlementLayerCallsPublic();

        // Verify the call data reflects the new gateway chain ID
        bytes memory expectedData1 = abi.encodeCall(IL1Bridgehub.registerSettlementLayer, (gatewayChainId, true));
        bytes memory expectedData2 = abi.encodeCall(IL1Bridgehub.registerSettlementLayer, (newGatewayChainId, true));

        assertEq(calls1[0].data, expectedData1, "First config call data should use original gatewayChainId");
        assertEq(calls2[0].data, expectedData2, "Second config call data should use new gatewayChainId");
    }

    /// @notice Test using GatewayPreparationForTests from existing test infrastructure
    function test_gatewayPreparationForTests_governanceRegisterGateway() public {
        // This tests the existing GatewayPreparationForTests script
        gatewayScript.governanceRegisterGateway();

        // Verify gateway is whitelisted as a settlement layer
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId),
            "Gateway should be whitelisted as settlement layer"
        );
    }

    /// @notice Test the full gateway registration flow
    function test_fullGatewayRegistrationFlow() public {
        // First register gateway as settlement layer
        gatewayScript.governanceRegisterGateway();

        // Deploy and set the transaction filterer
        gatewayScript.deployAndSetGatewayTransactionFilterer();

        // Verify the filterer is set
        address filterer = gatewayChain.getTransactionFilterer();
        assertTrue(filterer != address(0), "Transaction filterer should be deployed");

        // Perform full gateway registration
        gatewayScript.fullGatewayRegistration();

        // Verify gateway is still properly configured
        assertTrue(
            addresses.bridgehub.whitelistedSettlementLayers(gatewayChainId),
            "Gateway should remain whitelisted"
        );
    }

    /// @notice Helper function to initialize the gateway governance config for tests
    function _initializeTestGatewayGovernanceConfig() internal {
        GatewayGovernanceUtils.GatewayGovernanceConfig memory config = GatewayGovernanceUtils.GatewayGovernanceConfig({
            bridgehubProxy: address(addresses.bridgehub),
            l1AssetRouterProxy: address(addresses.sharedBridge),
            chainTypeManagerProxy: address(addresses.chainTypeManager),
            ctmDeploymentTrackerProxy: address(addresses.ctmDeploymentTracker),
            gatewayChainId: gatewayChainId
        });

        gatewayGovernanceUtils.initializeGatewayGovernanceConfigPublic(config);
    }

    // Exclude from coverage report
    function test() internal override {}
}
