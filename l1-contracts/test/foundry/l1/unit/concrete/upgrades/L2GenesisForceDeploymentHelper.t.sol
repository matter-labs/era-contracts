// SPDX-License-Identifier: MIT
// solhint-disable no-console, gas-custom-errors, state-visibility, no-global-import, one-contract-per-file, gas-calldata-parameters, no-unused-vars, func-named-parameters

pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "forge-std/console.sol";

import "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import "contracts/common/l2-helpers/L2ContractAddresses.sol";
import "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import "contracts/core/message-root/IMessageRoot.sol";
import "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import "contracts/core/bridgehub/L2Bridgehub.sol";
import "contracts/core/message-root/L2MessageRoot.sol";
import "contracts/bridge/asset-router/L2AssetRouter.sol";
import "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";
import "contracts/bridge/ntv/L2NativeTokenVaultZKOS.sol";
import "contracts/bridge/interfaces/IL2WrappedBaseToken.sol";
import "contracts/bridge/UpgradeableBeaconDeployer.sol";
import "contracts/l2-upgrades/SystemContractProxyAdmin.sol";
import "contracts/l2-upgrades/ISystemContractProxy.sol";

/**
 * @title L2GenesisForceDeploymentsHelperTest
 * @notice Tests for the L2GenesisForceDeploymentsHelper library covering both ZKsyncOS and Era deployment scenarios
 */
contract L2GenesisForceDeploymentsHelperTest is Test {
    using L2GenesisForceDeploymentsHelper for *;

    // Test constants
    uint256 constant L1_CHAIN_ID = 1;
    uint256 constant ERA_CHAIN_ID = 324;
    uint256 constant MAX_ZK_CHAINS = 100;

    // Test addresses
    address ctmDeployerAddress;
    address aliasedL1GovernanceAddress;
    address l1AssetRouterAddress;
    address baseTokenL1Address;

    // Mock contracts
    MockZKOSContractDeployer mockDeployer;
    MockSystemContractProxyAdmin mockProxyAdmin;

    function setUp() public {
        // Initialize test addresses
        ctmDeployerAddress = makeAddr("ctmDeployer");
        aliasedL1GovernanceAddress = makeAddr("aliasedL1Governance");
        l1AssetRouterAddress = makeAddr("l1AssetRouter");
        baseTokenL1Address = makeAddr("baseTokenL1Address");

        // Deploy and etch mock ZKsyncOS contract deployer
        mockDeployer = new MockZKOSContractDeployer();
        vm.etch(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, address(mockDeployer).code);

        // Deploy and etch mock SystemContractProxyAdmin
        mockProxyAdmin = new MockSystemContractProxyAdmin();
        vm.etch(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, address(mockProxyAdmin).code);

        // Set initial owner to the complex upgrader for most tests
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        MockSystemContractProxyAdmin(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR).forceSetOwner(L2_COMPLEX_UPGRADER_ADDR);

        // Deploy mock base token implementation
        MockContract mockBaseToken = new MockContract();
        vm.etch(L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, address(mockBaseToken).code);
    }

    function testZKsyncOSSystemProxyUpgrade_Genesis() public {
        FixedForceDeploymentsData memory fixedData = _createFixedForceDeploymentsData(true);
        ZKChainSpecificForceDeploymentsData memory additionalData = _createAdditionalForceDeploymentsData();

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory additionalEncoded = abi.encode(additionalData);
        _deployMockContract(GW_ASSET_TRACKER_ADDR);

        // Mock the SystemContractProxyAdmin.owner() call to return the expected owner
        vm.mockCall(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, abi.encodeWithSignature("owner()"), abi.encode(address(this)));

        // Record events to catch deployments
        vm.recordLogs();

        // Etch all deferred mock contracts now that deployment is complete
        _etchAllDeferredContracts();
        // Execute the deployment
        vm.startPrank(L2_COMPLEX_UPGRADER_ADDR);
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            true, // _isZKsyncOS
            ctmDeployerAddress,
            fixedEncoded,
            additionalEncoded,
            true // _isGenesisUpgrade
        );
        vm.stopPrank();

        // Verify deployments occurred - use the etched contract at the system address
        MockZKOSContractDeployer etchedDeployer = MockZKOSContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);
        assertEq(etchedDeployer.deploymentCount(L2_MESSAGE_ROOT_ADDR), 0); // proxy only
        assertEq(etchedDeployer.deploymentCount(L2_BRIDGEHUB_ADDR), 0);
        assertEq(etchedDeployer.deploymentCount(L2_ASSET_ROUTER_ADDR), 0);
        assertEq(etchedDeployer.deploymentCount(L2_NATIVE_TOKEN_VAULT_ADDR), 0);
        assertEq(etchedDeployer.deploymentCount(L2_CHAIN_ASSET_HANDLER_ADDR), 0);
        assertEq(etchedDeployer.deploymentCount(L2_NTV_BEACON_DEPLOYER_ADDR), 0);
        assertEq(etchedDeployer.deploymentCount(L2_INTEROP_CENTER_ADDR), 0);
        assertEq(etchedDeployer.deploymentCount(L2_INTEROP_HANDLER_ADDR), 0);
        assertEq(etchedDeployer.deploymentCount(L2_ASSET_TRACKER_ADDR), 0);

        // Verify proxy upgrades were called - use the etched contract at the system address
        MockSystemContractProxyAdmin etchedProxyAdmin = MockSystemContractProxyAdmin(
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
        );
        assertEq(etchedProxyAdmin.upgradeCallCount(), 0);
    }

    function testZKsyncOSSystemProxyUpgrade_NonGenesis() public {
        FixedForceDeploymentsData memory fixedData = _createFixedForceDeploymentsData(false);
        ZKChainSpecificForceDeploymentsData memory additionalData = _createAdditionalForceDeploymentsData();

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory additionalEncoded = abi.encode(additionalData);

        // Pre-deploy some mock contracts to simulate existing deployments
        // For non-genesis, the proxy should already exist, only impl gets updated
        _deployMockContract(L2_MESSAGE_ROOT_ADDR);
        _deployMockContract(L2_BRIDGEHUB_ADDR);
        _deployMockContract(L2_ASSET_ROUTER_ADDR);
        _deployMockContract(L2_NATIVE_TOKEN_VAULT_ADDR);
        _deployMockContract(L2_CHAIN_ASSET_HANDLER_ADDR);
        _deployMockContract(GW_ASSET_TRACKER_ADDR);

        vm.mockCall(L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR, abi.encodeWithSignature("owner()"), abi.encode(address(this)));

        vm.startPrank(L2_COMPLEX_UPGRADER_ADDR);
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            true, // _isZKsyncOS
            ctmDeployerAddress,
            fixedEncoded,
            additionalEncoded,
            false // _isGenesisUpgrade
        );
        vm.stopPrank();

        // For non-genesis, existing contracts should only get implementation updates
        // No new deployments to the target addresses since proxies already exist
        MockZKOSContractDeployer etchedDeployer = MockZKOSContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);
        assertEq(etchedDeployer.deploymentCount(L2_MESSAGE_ROOT_ADDR), 0); // no new deployment
        assertEq(etchedDeployer.deploymentCount(L2_BRIDGEHUB_ADDR), 0);
        assertEq(etchedDeployer.deploymentCount(L2_ASSET_ROUTER_ADDR), 0);
        assertEq(etchedDeployer.deploymentCount(L2_NATIVE_TOKEN_VAULT_ADDR), 0);
        assertEq(etchedDeployer.deploymentCount(L2_CHAIN_ASSET_HANDLER_ADDR), 0);

        // Verify proxy upgrades were called
        MockSystemContractProxyAdmin etchedProxyAdmin = MockSystemContractProxyAdmin(
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
        );
        assertEq(etchedProxyAdmin.upgradeCallCount(), 8);
    }

    function testEraForceDeployment() public {
        FixedForceDeploymentsData memory fixedData = _createEraFixedForceDeploymentsData();
        ZKChainSpecificForceDeploymentsData memory additionalData = _createAdditionalForceDeploymentsData();

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory additionalEncoded = abi.encode(additionalData);
        _deployMockContract(GW_ASSET_TRACKER_ADDR);

        // Etch L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR for initializeBaseTokenHolderBalance call during genesis
        _deployMockContract(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);

        // For Era deployments, no proxy admin is needed
        vm.startPrank(L2_COMPLEX_UPGRADER_ADDR);
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            false, // _isZKsyncOS
            ctmDeployerAddress,
            fixedEncoded,
            additionalEncoded,
            true // _isGenesisUpgrade
        );
        vm.stopPrank();

        // Era deployments should use direct force deployment (single deployment per address)
        MockZKOSContractDeployer etchedDeployer = MockZKOSContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);
        assertEq(etchedDeployer.deploymentCount(L2_MESSAGE_ROOT_ADDR), 1);
        assertEq(etchedDeployer.deploymentCount(L2_BRIDGEHUB_ADDR), 1);
        assertEq(etchedDeployer.deploymentCount(L2_ASSET_ROUTER_ADDR), 1);
        assertEq(etchedDeployer.deploymentCount(L2_NATIVE_TOKEN_VAULT_ADDR), 1);
        assertEq(etchedDeployer.deploymentCount(L2_CHAIN_ASSET_HANDLER_ADDR), 1);
        assertEq(etchedDeployer.deploymentCount(L2_NTV_BEACON_DEPLOYER_ADDR), 1);

        // No proxy upgrades for Era
        MockSystemContractProxyAdmin etchedProxyAdmin = MockSystemContractProxyAdmin(
            L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
        );
        assertEq(etchedProxyAdmin.upgradeCallCount(), 0);
    }

    // Helper functions

    function _createFixedForceDeploymentsData(bool isGenesis) internal view returns (FixedForceDeploymentsData memory) {
        FixedForceDeploymentsData memory data;
        data.l1ChainId = L1_CHAIN_ID;
        data.eraChainId = ERA_CHAIN_ID;
        data.aliasedL1Governance = aliasedL1GovernanceAddress;
        data.maxNumberOfZKChains = MAX_ZK_CHAINS;
        data.l1AssetRouter = l1AssetRouterAddress;

        // For ZKsyncOS, bytecode info is (implementation, proxy) tuple
        data.messageRootBytecodeInfo = abi.encode(
            abi.encode(keccak256("messageroot_impl"), uint32(0), bytes32(0)),
            abi.encode(keccak256("messageroot_proxy"), uint32(0), bytes32(0))
        );
        data.bridgehubBytecodeInfo = abi.encode(
            abi.encode(keccak256("bridgehub_impl"), uint32(0), bytes32(0)),
            abi.encode(keccak256("bridgehub_proxy"), uint32(0), bytes32(0))
        );
        data.l2AssetRouterBytecodeInfo = abi.encode(
            abi.encode(keccak256("assetRouter_impl"), uint32(0), bytes32(0)),
            abi.encode(keccak256("assetRouter_proxy"), uint32(0), bytes32(0))
        );
        data.l2NtvBytecodeInfo = abi.encode(
            abi.encode(keccak256("ntv_impl"), uint32(0), bytes32(0)),
            abi.encode(keccak256("ntv_proxy"), uint32(0), bytes32(0))
        );
        data.chainAssetHandlerBytecodeInfo = abi.encode(
            abi.encode(keccak256("chainHandler_impl"), uint32(0), bytes32(0)),
            abi.encode(keccak256("chainHandler_proxy"), uint32(0), bytes32(0))
        );
        data.interopCenterBytecodeInfo = abi.encode(
            abi.encode(keccak256("interopCenter_impl"), uint32(0), bytes32(0)),
            abi.encode(keccak256("interopCenter_proxy"), uint32(0), bytes32(0))
        );
        data.interopHandlerBytecodeInfo = abi.encode(
            abi.encode(keccak256("interopHandler_impl"), uint32(0), bytes32(0)),
            abi.encode(keccak256("interopHandler_proxy"), uint32(0), bytes32(0))
        );
        data.assetTrackerBytecodeInfo = abi.encode(
            abi.encode(keccak256("assetTracker_impl"), uint32(0), bytes32(0)),
            abi.encode(keccak256("assetTracker_proxy"), uint32(0), bytes32(0))
        );

        if (isGenesis) {
            data.beaconDeployerInfo = abi.encode(
                abi.encode(keccak256("beaconDeployer_impl"), uint32(0), bytes32(0)),
                abi.encode(keccak256("beaconDeployer_proxy"), uint32(0), bytes32(0))
            );
        } else {
            data.beaconDeployerInfo = "";
        }

        return data;
    }

    function _createEraFixedForceDeploymentsData() internal view returns (FixedForceDeploymentsData memory) {
        FixedForceDeploymentsData memory data;
        data.l1ChainId = L1_CHAIN_ID;
        data.eraChainId = ERA_CHAIN_ID;
        data.aliasedL1Governance = aliasedL1GovernanceAddress;
        data.maxNumberOfZKChains = MAX_ZK_CHAINS;
        data.l1AssetRouter = l1AssetRouterAddress;

        // For Era, bytecode info is just a single bytecode hash
        data.messageRootBytecodeInfo = abi.encode(keccak256("messageroot"));
        data.bridgehubBytecodeInfo = abi.encode(keccak256("bridgehub"));
        data.l2AssetRouterBytecodeInfo = abi.encode(keccak256("assetRouter"));
        data.l2NtvBytecodeInfo = abi.encode(keccak256("ntv"));
        data.chainAssetHandlerBytecodeInfo = abi.encode(keccak256("chainHandler"));
        data.interopCenterBytecodeInfo = abi.encode(keccak256("interopCenter"));
        data.interopHandlerBytecodeInfo = abi.encode(keccak256("interopHandler"));
        data.assetTrackerBytecodeInfo = abi.encode(keccak256("assetTracker"));
        data.beaconDeployerInfo = abi.encode(keccak256("beaconDeployer"));

        return data;
    }

    function _createAdditionalForceDeploymentsData()
        internal
        view
        returns (ZKChainSpecificForceDeploymentsData memory)
    {
        ZKChainSpecificForceDeploymentsData memory data;
        data.baseTokenBridgingData.assetId = keccak256("baseTokenAsset");
        data.baseTokenL1Address = baseTokenL1Address;
        data.baseTokenBridgingData.originToken = address(1);
        data.baseTokenBridgingData.originChainId = 1;
        data.baseTokenMetadata.name = "Ether";
        data.baseTokenMetadata.symbol = "ETH";
        data.baseTokenMetadata.decimals = 18;
        return data;
    }

    function _deployMockContract(address addr) internal {
        MockContract mock = new MockContract();
        vm.etch(addr, address(mock).code);
    }

    function _etchAllDeferredContracts() internal {
        // Etch contracts to addresses that need function calls to work
        address[] memory addressesToEtch = new address[](10);
        addressesToEtch[0] = L2_MESSAGE_ROOT_ADDR;
        addressesToEtch[1] = L2_BRIDGEHUB_ADDR;
        addressesToEtch[2] = L2_ASSET_ROUTER_ADDR;
        addressesToEtch[3] = L2_NATIVE_TOKEN_VAULT_ADDR;
        addressesToEtch[4] = L2_CHAIN_ASSET_HANDLER_ADDR;
        addressesToEtch[5] = L2_NTV_BEACON_DEPLOYER_ADDR;
        addressesToEtch[6] = L2_INTEROP_CENTER_ADDR;
        addressesToEtch[7] = L2_INTEROP_HANDLER_ADDR;
        addressesToEtch[8] = L2_ASSET_TRACKER_ADDR;
        addressesToEtch[9] = L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR;

        for (uint256 i = 0; i < addressesToEtch.length; i++) {
            if (addressesToEtch[i].code.length == 0) {
                MockContract mock = new MockContract();
                vm.etch(addressesToEtch[i], address(mock).code);
            }
        }
    }
}

// Mock contracts

contract MockZKOSContractDeployer {
    mapping(address => uint256) public deploymentCount;
    mapping(address => bytes32) public lastBytecodeHash;
    mapping(address => bool) private _deferredEtchAddresses;

    event MockDeploy(address addr, bytes32 bytecodeHash);

    function setBytecodeDetailsEVM(
        address _addr,
        bytes32 _bytecodeHash,
        uint32 _bytecodeLength,
        bytes32 _observableBytecodeHash
    ) external {
        deploymentCount[_addr]++;
        lastBytecodeHash[_addr] = _bytecodeHash;
        emit MockDeploy(_addr, _bytecodeHash);

        // For proxy addresses, etch immediately after deployment but preserve initial code check
        // The issue is that forceInitAdmin is called immediately after setBytecodeDetailsEVM
        if (_addr.code.length == 0) {
            MockContract mock = new MockContract();
            Vm vm = Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));
            vm.etch(_addr, address(mock).code);
        }
    }

    function forceDeployOnAddresses(IL2ContractDeployer.ForceDeployment[] calldata _deployments) external {
        for (uint256 i = 0; i < _deployments.length; i++) {
            deploymentCount[_deployments[i].newAddress]++;
            lastBytecodeHash[_deployments[i].newAddress] = _deployments[i].bytecodeHash;
            emit MockDeploy(_deployments[i].newAddress, _deployments[i].bytecodeHash);

            // Etch immediately for Era deployments (no proxy logic)
            if (_deployments[i].newAddress.code.length == 0) {
                MockContract mock = new MockContract();
                Vm vm = Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));
                vm.etch(_deployments[i].newAddress, address(mock).code);
            }
        }
    }
}

contract MockSystemContractProxyAdmin {
    uint256 private _upgradeCallCount;
    address public owner;

    modifier onlyUpgrader() {
        require(msg.sender == L2_COMPLEX_UPGRADER_ADDR, "Unauthorized");
        _;
    }

    function upgrade(address, address) external {
        require(msg.sender == owner, "Caller is not the owner");
        _upgradeCallCount++;
    }

    function upgradeCallCount() external view returns (uint256) {
        return _upgradeCallCount;
    }

    function forceSetOwner(address _newOwner) external onlyUpgrader {
        owner = _newOwner;
    }
}

contract MockContract {
    // Generic mock contract that can handle various function calls
    function forceInitAdmin(address) external {}

    function initL2(uint256) external {}

    function initL2(uint256, address, uint256) external {}

    function initL2(uint256, uint256, address, address, bytes32, address) external {}

    function initL2(uint256, address, bytes32, address, address, address, bytes32) external {}

    function initL2(uint256, address, address, address, address) external {}

    function updateL2(uint256, bytes32, address, address, bytes32) external {}

    function updateL2(uint256, address, address, address) external {}

    function updateL2(uint256, uint256) external {}

    function deployUpgradeableBeacon(address) external returns (address) {
        return makeAddr("upgradeableBeacon");
    }

    function setAddresses(address, address, address, address) external {}

    function L2_LEGACY_SHARED_BRIDGE() external view returns (address) {
        return address(0);
    }

    function WETH_TOKEN() external view returns (address) {
        return makeAddr("wethToken");
    }

    function L2_TOKEN_PROXY_BYTECODE_HASH() external view returns (bytes32) {
        return bytes32(0);
    }

    function initializeV3(string memory, string memory, address, address, bytes32) external {}

    function initializeBaseTokenHolderBalance() external {}

    function makeAddr(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(name)))));
    }

    // Fallback to handle any other calls
    fallback() external payable {
        // Return success for any unmocked calls
    }
}
