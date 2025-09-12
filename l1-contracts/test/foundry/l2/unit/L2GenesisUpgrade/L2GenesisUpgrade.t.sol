// FIXME decide what to do with L2ComplexUpgrader + L2GenesisUpgrade tests, when they are out of system-contracts
// For now they are ignored

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2GenesisUpgrade} from "contracts/l2-upgrades/L2GenesisUpgrade.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {MockContract} from "contracts/dev-contracts/MockContract.sol";

contract L2GenesisUpgradeTest is Test {
    L2GenesisUpgrade internal l2GenesisUpgrade;
    L2ComplexUpgrader internal complexUpgrader;

    address internal constant TEST_L2_GENESIS_UPGRADE_CONTRACT_ADDRESS = address(0x10001);
    address internal constant TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS = address(0x900f);
    address internal constant TEST_FORCE_DEPLOYER_ADDRESS = address(0x9007);
    address internal constant REAL_L2_ASSET_ROUTER_ADDRESS = address(0x10003);
    address internal constant REAL_L2_MESSAGE_ROOT_ADDRESS = address(0x10005);
    address internal constant REAL_L2_CHAIN_ASSET_HANDLER_ADDRESS = address(0x1000a);
    address internal constant ADDRESS_ONE = address(0x1);

    // System contract addresses for mocking
    address internal constant TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS = address(0x900b);
    address internal constant TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS = address(0x9006);
    address internal constant REAL_BRIDGEHUB_ADDRESS = address(0x10002);

    uint256 internal constant chainId = 270;
    address internal ctmDeployerAddress;
    address internal bridgehubOwnerAddress;

    bytes internal fixedForceDeploymentsData;
    bytes internal additionalForceDeploymentsData;

    event UpgradeComplete(uint256 _chainId);

    function setUp() public {
        // Generate random addresses for test
        ctmDeployerAddress = makeAddr("ctmDeployer");
        bridgehubOwnerAddress = makeAddr("bridgehubOwner");

        // Deploy system contracts at their addresses
        _deploySystemContractMocks();

        // Deploy and setup L2ComplexUpgrader
        bytes memory complexUpgraderBytecode = abi.encodePacked(type(L2ComplexUpgrader).creationCode);
        vm.etch(TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS, complexUpgraderBytecode);
        complexUpgrader = L2ComplexUpgrader(TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS);

        // Deploy and setup L2GenesisUpgrade
        bytes memory genesisUpgradeBytecode = abi.encodePacked(type(L2GenesisUpgrade).creationCode);
        vm.etch(TEST_L2_GENESIS_UPGRADE_CONTRACT_ADDRESS, genesisUpgradeBytecode);
        l2GenesisUpgrade = L2GenesisUpgrade(TEST_L2_GENESIS_UPGRADE_CONTRACT_ADDRESS);

        // Setup mock contract responses
        _setupMockResponses();

        // Prepare upgrade data
        _prepareUpgradeData();
    }

    function _deploySystemContractMocks() internal {
        // Deploy MockContract at system addresses
        bytes memory mockBytecode = abi.encodePacked(type(MockContract).creationCode);

        vm.etch(TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS, mockBytecode);
        vm.etch(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS, mockBytecode);
        vm.etch(REAL_BRIDGEHUB_ADDRESS, mockBytecode);
    }

    function _setupMockResponses() internal {
        MockContract bridgehubMock = MockContract(payable(REAL_BRIDGEHUB_ADDRESS));
        MockContract systemContextMock = MockContract(payable(TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS));
        MockContract deployerMock = MockContract(payable(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS));

        // Setup IBridgehub.setAddresses response
        bytes memory setAddressesCall = abi.encodeWithSignature(
            "setAddresses(address,address,address,address)",
            REAL_L2_ASSET_ROUTER_ADDRESS,
            ctmDeployerAddress,
            REAL_L2_MESSAGE_ROOT_ADDRESS,
            REAL_L2_CHAIN_ASSET_HANDLER_ADDRESS
        );
        bridgehubMock.setResult(MockContract.CallResult({input: setAddressesCall, failure: false, returnData: ""}));

        // Setup IBridgehub.owner response
        bytes memory ownerCall = abi.encodeWithSignature("owner()");
        bridgehubMock.setResult(
            MockContract.CallResult({input: ownerCall, failure: false, returnData: abi.encode(bridgehubOwnerAddress)})
        );

        // Setup SystemContext.setChainId response
        bytes memory setChainIdCall = abi.encodeWithSignature("setChainId(uint256)", chainId);
        systemContextMock.setResult(MockContract.CallResult({input: setChainIdCall, failure: false, returnData: ""}));

        // Setup ContractDeployer.forceDeployOnAddresses response
        // Create force deployment struct
        bytes memory forceDeployments = abi.encode(
            [
                abi.encode(
                    bytes32(0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70),
                    address(0x20002),
                    true,
                    uint256(0),
                    bytes("")
                )
            ]
        );
        bytes memory forceDeployCall = abi.encodeWithSignature(
            "forceDeployOnAddresses((bytes32,address,bool,uint256,bytes)[])",
            forceDeployments
        );
        deployerMock.setResult(MockContract.CallResult({input: forceDeployCall, failure: false, returnData: ""}));
    }

    function _prepareUpgradeData() internal {
        // Prepare additional force deployments data
        additionalForceDeploymentsData = abi.encode(
            bytes32(0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70),
            address(0),
            ADDRESS_ONE,
            ADDRESS_ONE,
            "Ether",
            "ETH"
        );

        // Create mock bytecode hashes
        bytes32 mockBytecodeHash = bytes32(0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70);

        // Prepare fixed force deployments data
        fixedForceDeploymentsData = abi.encode(
            uint256(1), // l1ChainId
            uint256(1), // eraChainId
            ADDRESS_ONE, // l1AssetRouter
            mockBytecodeHash, // l2TokenProxyBytecodeHash
            ADDRESS_ONE, // aliasedL1Governance
            uint256(100), // maxNumberOfZKChains
            mockBytecodeHash, // bridgehubBytecodeHash
            mockBytecodeHash, // l2AssetRouterBytecodeHash
            mockBytecodeHash, // l2NtvBytecodeHash
            mockBytecodeHash, // messageRootBytecodeHash
            mockBytecodeHash, // chainAssetHandlerBytecodeHash
            address(0), // l2SharedBridgeLegacyImpl
            address(0), // l2BridgedStandardERC20Impl
            address(0) // dangerousTestOnlyForcedBeacon
        );
    }

    function test_SuccessfullyUpgraded() public {
        // Encode the genesis upgrade call
        bytes memory data = abi.encodeWithSignature(
            "genesisUpgrade(bool,uint256,address,bytes,bytes)",
            false, // _isZKsyncOS
            chainId,
            ctmDeployerAddress,
            fixedForceDeploymentsData,
            additionalForceDeploymentsData
        );

        // Impersonate the force deployer and execute the upgrade
        vm.prank(TEST_FORCE_DEPLOYER_ADDRESS);

        // Expect the UpgradeComplete event to be emitted
        vm.expectEmit(true, true, true, true, TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS);
        emit UpgradeComplete(chainId);

        // Execute the upgrade through the complex upgrader
        complexUpgrader.upgrade(address(l2GenesisUpgrade), data);
    }
}
