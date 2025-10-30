// SPDX-License-Identifier: MIT
// solhint-disable no-console, gas-custom-errors, state-visibility, no-global-import, one-contract-per-file, gas-calldata-parameters, no-unused-vars, func-named-parameters
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import "contracts/common/l2-helpers/L2ContractAddresses.sol";
import "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import "contracts/bridgehub/IMessageRoot.sol";
import "contracts/bridgehub/ICTMDeploymentTracker.sol";
import "contracts/bridgehub/L2Bridgehub.sol";
import "contracts/bridgehub/L2MessageRoot.sol";
import "contracts/bridge/asset-router/L2AssetRouter.sol";
import "contracts/bridgehub/L2ChainAssetHandler.sol";
import "contracts/bridge/ntv/L2NativeTokenVaultZKOS.sol";
import "contracts/bridge/ntv/L2NativeTokenVault.sol";
import "contracts/bridge/ntv/UpgradeableBeaconDeployer.sol";
import "contracts/bridge/interfaces/IL2WrappedBaseToken.sol";
import "contracts/common/L1ContractErrors.sol";

contract MockZKOSContractDeployer {
    mapping(address => bytes32) public deployedBytecodes;
    mapping(address => bool) public deploymentFailed;

    function setBytecodeDetailsEVM(
        address _addr,
        bytes32 _bytecodeHash,
        uint32 _bytecodeLength,
        bytes32 _observableBytecodeHash
    ) external {
        if (deploymentFailed[_addr]) {
            revert("Mock deployment failure");
        }
        deployedBytecodes[_addr] = _bytecodeHash;
    }

    function forceDeployOnAddresses(IL2ContractDeployer.ForceDeployment[] calldata _deployments) external {
        for (uint256 i = 0; i < _deployments.length; i++) {
            if (deploymentFailed[_deployments[i].newAddress]) {
                revert("Mock deployment failure");
            }
            deployedBytecodes[_deployments[i].newAddress] = _deployments[i].bytecodeHash;
        }
    }

    function setDeploymentFailure(address _addr, bool _shouldFail) external {
        deploymentFailed[_addr] = _shouldFail;
    }
}

contract MockBaseToken {}

contract L2GenesisForceDeploymentsInitTest is Test {
    using L2GenesisForceDeploymentsHelper for *;

    // Fake deployer address for CTM
    address ctmDeployer = makeAddr("ctmDeployer");

    MockZKOSContractDeployer deployer;

    MockBaseToken mockBaseToken;

    // Test data
    uint256 constant L1_CHAIN_ID = 111;
    uint256 constant ERA_CHAIN_ID = 222;
    uint256 constant MAX_ZK_CHAINS = 5;
    bytes32 constant BASE_TOKEN_ASSET_ID = keccak256("baseTokenAsset");
    string constant BASE_TOKEN_NAME = "Ether";
    string constant BASE_TOKEN_SYMBOL = "ETH";

    address aliasedL1Governance;
    address l1AssetRouter;
    address baseTokenL1Address;
    address upgradeableBeacon;
    address wethToken;

    function setUp() public {
        MockZKOSContractDeployer mock = new MockZKOSContractDeployer();
        vm.etch(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, address(mock).code);
        deployer = MockZKOSContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);

        mockBaseToken = new MockBaseToken();
        vm.etch(L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, address(mockBaseToken).code);

        // Initialize test addresses
        aliasedL1Governance = makeAddr("aliasedL1Governance");
        l1AssetRouter = makeAddr("l1AssetRouter");
        baseTokenL1Address = makeAddr("baseTokenL1Address");
        upgradeableBeacon = makeAddr("upgradeableBeacon");
        wethToken = makeAddr("wethToken");
    }

    function _createFixedData() internal view returns (FixedForceDeploymentsData memory) {
        FixedForceDeploymentsData memory fixedData;
        fixedData.l1ChainId = L1_CHAIN_ID;
        fixedData.eraChainId = ERA_CHAIN_ID;
        fixedData.aliasedL1Governance = aliasedL1Governance;
        fixedData.maxNumberOfZKChains = MAX_ZK_CHAINS;
        fixedData.l1AssetRouter = l1AssetRouter;
        fixedData.messageRootBytecodeInfo = abi.encode(bytes32(keccak256("messageroot")), uint32(1000), bytes32(keccak256("observable_messageroot")));
        fixedData.bridgehubBytecodeInfo = abi.encode(bytes32(keccak256("bridgehub")), uint32(2000), bytes32(keccak256("observable_bridgehub")));
        fixedData.l2AssetRouterBytecodeInfo = abi.encode(bytes32(keccak256("assetRouter")), uint32(3000), bytes32(keccak256("observable_assetRouter")));
        fixedData.l2NtvBytecodeInfo = abi.encode(bytes32(keccak256("ntv")), uint32(4000), bytes32(keccak256("observable_ntv")));
        fixedData.chainAssetHandlerBytecodeInfo = abi.encode(bytes32(keccak256("chainHandler")), uint32(5000), bytes32(keccak256("observable_chainHandler")));
        return fixedData;
    }

    function _createAdditionalData() internal view returns (ZKChainSpecificForceDeploymentsData memory) {
        ZKChainSpecificForceDeploymentsData memory addData;
        addData.baseTokenAssetId = BASE_TOKEN_ASSET_ID;
        addData.baseTokenL1Address = baseTokenL1Address;
        addData.baseTokenName = BASE_TOKEN_NAME;
        addData.baseTokenSymbol = BASE_TOKEN_SYMBOL;
        return addData;
    }

    function testForceDeployment_zkos_Genesis() public {
        FixedForceDeploymentsData memory fixedData = _createFixedData();
        fixedData.beaconDeployerInfo = abi.encode(bytes32(keccak256("beaconDeployer")), uint32(6000), bytes32(keccak256("observable_beaconDeployer")));
        
        ZKChainSpecificForceDeploymentsData memory addData = _createAdditionalData();

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory addEncoded = abi.encode(addData);

        // Expect exact parameter validation for initialization calls
        vm.expectCall(
            L2_MESSAGE_ROOT_ADDR,
            abi.encodeWithSelector(L2MessageRoot.initL2.selector, L1_CHAIN_ID)
        );
        
        vm.expectCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(
                L2Bridgehub.initL2.selector,
                L1_CHAIN_ID,
                aliasedL1Governance,
                MAX_ZK_CHAINS
            )
        );

        vm.expectCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(
                L2AssetRouter.initL2.selector,
                L1_CHAIN_ID,
                ERA_CHAIN_ID,
                l1AssetRouter,
                address(0), // legacy bridge is 0 for genesis
                BASE_TOKEN_ASSET_ID,
                aliasedL1Governance
            )
        );

        vm.expectCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(
                L2ChainAssetHandler.initL2.selector,
                L1_CHAIN_ID,
                aliasedL1Governance,
                L2_BRIDGEHUB_ADDR,
                L2_ASSET_ROUTER_ADDR,
                L2_MESSAGE_ROOT_ADDR
            )
        );

        vm.expectCall(
            L2_NTV_BEACON_DEPLOYER_ADDR,
            abi.encodeWithSelector(
                UpgradeableBeaconDeployer.deployUpgradeableBeacon.selector,
                aliasedL1Governance
            )
        );

        vm.expectCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(
                L2Bridgehub.setAddresses.selector,
                L2_ASSET_ROUTER_ADDR,
                ctmDeployer,
                L2_MESSAGE_ROOT_ADDR,
                L2_CHAIN_ASSET_HANDLER_ADDR
            )
        );

        // Mock calls for contracts that will be invoked
        vm.mockCall(L2_MESSAGE_ROOT_ADDR, abi.encodeWithSelector(L2MessageRoot.initL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.initL2.selector), "");
        vm.mockCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(L2AssetRouter.initL2.selector), "");
        vm.mockCall(L2_CHAIN_ASSET_HANDLER_ADDR, abi.encodeWithSelector(L2ChainAssetHandler.initL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.setAddresses.selector), "");
        vm.mockCall(
            L2_NTV_BEACON_DEPLOYER_ADDR,
            abi.encodeWithSelector(UpgradeableBeaconDeployer.deployUpgradeableBeacon.selector),
            abi.encode(upgradeableBeacon)
        );
        vm.mockCall(
            L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
            abi.encodeWithSelector(IL2WrappedBaseToken.initializeV3.selector),
            ""
        );
        vm.mockCall(L2_NATIVE_TOKEN_VAULT_ADDR, abi.encodeWithSelector(L2NativeTokenVault.initL2.selector), "");

        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            true, // _isZKsyncOS
            ctmDeployer,
            fixedEncoded,
            addEncoded,
            true // _isGenesisUpgrade
        );

        // Verify correct bytecodes were deployed
        assertEq(deployer.deployedBytecodes(L2_MESSAGE_ROOT_ADDR), keccak256("messageroot"));
        assertEq(deployer.deployedBytecodes(L2_BRIDGEHUB_ADDR), keccak256("bridgehub"));
        assertEq(deployer.deployedBytecodes(L2_ASSET_ROUTER_ADDR), keccak256("assetRouter"));
        assertEq(deployer.deployedBytecodes(L2_NATIVE_TOKEN_VAULT_ADDR), keccak256("ntv"));
        assertEq(deployer.deployedBytecodes(L2_CHAIN_ASSET_HANDLER_ADDR), keccak256("chainHandler"));
        assertEq(deployer.deployedBytecodes(L2_NTV_BEACON_DEPLOYER_ADDR), keccak256("beaconDeployer"));
    }

    function testForceDeployment_zkos_NotGenesis() public {
        FixedForceDeploymentsData memory fixedData = _createFixedData();
        // Not used for non-genesis upgrade
        fixedData.beaconDeployerInfo = "";
        
        ZKChainSpecificForceDeploymentsData memory addData = _createAdditionalData();
        address legacyBridge = makeAddr("legacyBridge");

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory addEncoded = abi.encode(addData);

        // Expect update calls instead of init calls for non-genesis
        vm.expectCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(
                L2Bridgehub.updateL2.selector,
                L1_CHAIN_ID,
                MAX_ZK_CHAINS
            )
        );

        vm.expectCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(
                L2AssetRouter.updateL2.selector,
                L1_CHAIN_ID,
                ERA_CHAIN_ID,
                l1AssetRouter,
                legacyBridge,
                BASE_TOKEN_ASSET_ID
            )
        );

        vm.expectCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(
                L2ChainAssetHandler.updateL2.selector,
                L1_CHAIN_ID,
                L2_BRIDGEHUB_ADDR,
                L2_ASSET_ROUTER_ADDR,
                L2_MESSAGE_ROOT_ADDR
            )
        );

        vm.expectCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(
                L2Bridgehub.setAddresses.selector,
                L2_ASSET_ROUTER_ADDR,
                ctmDeployer,
                L2_MESSAGE_ROOT_ADDR,
                L2_CHAIN_ASSET_HANDLER_ADDR
            )
        );

        // Mock existing contract state queries for non-genesis upgrade
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(bytes4(keccak256("L2_LEGACY_SHARED_BRIDGE()"))),
            abi.encode(legacyBridge)
        );
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(bytes4(keccak256("WETH_TOKEN()"))),
            abi.encode(wethToken)
        );
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(bytes4(keccak256("L2_TOKEN_PROXY_BYTECODE_HASH()"))),
            abi.encode(bytes32(uint256(0x1234)))
        );

        // Mock the contract calls
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.updateL2.selector), "");
        vm.mockCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(L2AssetRouter.updateL2.selector), "");
        vm.mockCall(L2_NATIVE_TOKEN_VAULT_ADDR, abi.encodeWithSelector(L2NativeTokenVault.updateL2.selector), "");
        vm.mockCall(L2_CHAIN_ASSET_HANDLER_ADDR, abi.encodeWithSelector(L2ChainAssetHandler.updateL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.setAddresses.selector), "");

        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            true, // _isZKsyncOS
            ctmDeployer,
            fixedEncoded,
            addEncoded,
            false // _isGenesisUpgrade
        );

        // Verify correct bytecodes were deployed
        assertEq(deployer.deployedBytecodes(L2_MESSAGE_ROOT_ADDR), keccak256("messageroot"));
        assertEq(deployer.deployedBytecodes(L2_BRIDGEHUB_ADDR), keccak256("bridgehub"));
        assertEq(deployer.deployedBytecodes(L2_ASSET_ROUTER_ADDR), keccak256("assetRouter"));
        assertEq(deployer.deployedBytecodes(L2_NATIVE_TOKEN_VAULT_ADDR), keccak256("ntv"));
        assertEq(deployer.deployedBytecodes(L2_CHAIN_ASSET_HANDLER_ADDR), keccak256("chainHandler"));
        // Beacon deployer should NOT be deployed in non-genesis upgrade
        assertEq(deployer.deployedBytecodes(L2_NTV_BEACON_DEPLOYER_ADDR), bytes32(0));
    }

    function testForceDeployment_Era_Genesis() public {
        FixedForceDeploymentsData memory fixedData = _createFixedData();
        fixedData.beaconDeployerInfo = abi.encode(bytes32(keccak256("beaconDeployer")));
        
        ZKChainSpecificForceDeploymentsData memory addData = _createAdditionalData();

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory addEncoded = abi.encode(addData);

        // Mock all necessary calls for Era deployment (different from ZKsyncOS)
        vm.mockCall(L2_MESSAGE_ROOT_ADDR, abi.encodeWithSelector(L2MessageRoot.initL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.initL2.selector), "");
        vm.mockCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(L2AssetRouter.initL2.selector), "");
        vm.mockCall(L2_CHAIN_ASSET_HANDLER_ADDR, abi.encodeWithSelector(L2ChainAssetHandler.initL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.setAddresses.selector), "");
        vm.mockCall(
            L2_NTV_BEACON_DEPLOYER_ADDR,
            abi.encodeWithSelector(UpgradeableBeaconDeployer.deployUpgradeableBeacon.selector),
            abi.encode(upgradeableBeacon)
        );
        vm.mockCall(
            L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
            abi.encodeWithSelector(IL2WrappedBaseToken.initializeV3.selector),
            ""
        );
        vm.mockCall(L2_NATIVE_TOKEN_VAULT_ADDR, abi.encodeWithSelector(L2NativeTokenVault.initL2.selector), "");

        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            false, // _isZKsyncOS = false for Era
            ctmDeployer,
            fixedEncoded,
            addEncoded,
            true // _isGenesisUpgrade
        );

        // For Era deployment, bytecode should be deployed via different mechanism
        assertEq(deployer.deployedBytecodes(L2_MESSAGE_ROOT_ADDR), keccak256("messageroot"));
        assertEq(deployer.deployedBytecodes(L2_BRIDGEHUB_ADDR), keccak256("bridgehub"));
        assertEq(deployer.deployedBytecodes(L2_ASSET_ROUTER_ADDR), keccak256("assetRouter"));
        assertEq(deployer.deployedBytecodes(L2_NATIVE_TOKEN_VAULT_ADDR), keccak256("ntv"));
        assertEq(deployer.deployedBytecodes(L2_CHAIN_ASSET_HANDLER_ADDR), keccak256("chainHandler"));
        assertEq(deployer.deployedBytecodes(L2_NTV_BEACON_DEPLOYER_ADDR), keccak256("beaconDeployer"));
    }

    function testForceDeployment_DeploymentFailure() public {
        FixedForceDeploymentsData memory fixedData = _createFixedData();
        fixedData.beaconDeployerInfo = abi.encode(bytes32(keccak256("beaconDeployer")), uint32(6000), bytes32(keccak256("observable_beaconDeployer")));
        
        ZKChainSpecificForceDeploymentsData memory addData = _createAdditionalData();

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory addEncoded = abi.encode(addData);

        // Set deployment to fail for message root
        deployer.setDeploymentFailure(L2_MESSAGE_ROOT_ADDR, true);

        // Add all the mocks that are needed, even though we expect to fail early
        vm.mockCall(L2_MESSAGE_ROOT_ADDR, abi.encodeWithSelector(L2MessageRoot.initL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.initL2.selector), "");
        vm.mockCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(L2AssetRouter.initL2.selector), "");
        vm.mockCall(L2_CHAIN_ASSET_HANDLER_ADDR, abi.encodeWithSelector(L2ChainAssetHandler.initL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.setAddresses.selector), "");
        vm.mockCall(
            L2_NTV_BEACON_DEPLOYER_ADDR,
            abi.encodeWithSelector(UpgradeableBeaconDeployer.deployUpgradeableBeacon.selector),
            abi.encode(upgradeableBeacon)
        );
        vm.mockCall(
            L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
            abi.encodeWithSelector(IL2WrappedBaseToken.initializeV3.selector),
            ""
        );
        vm.mockCall(L2_NATIVE_TOKEN_VAULT_ADDR, abi.encodeWithSelector(L2NativeTokenVault.initL2.selector), "");

        vm.expectRevert();
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            true, // _isZKsyncOS
            ctmDeployer,
            fixedEncoded,
            addEncoded,
            true // _isGenesisUpgrade
        );
    }

    function testForceDeployment_InvalidBytecodeData() public {
        FixedForceDeploymentsData memory fixedData = _createFixedData();
        // Invalid bytecode info - missing required fields
        fixedData.messageRootBytecodeInfo = abi.encode(bytes32(0));
        
        ZKChainSpecificForceDeploymentsData memory addData = _createAdditionalData();

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory addEncoded = abi.encode(addData);

        // Should revert due to malformed bytecode data
        vm.expectRevert();
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            true, // _isZKsyncOS
            ctmDeployer,
            fixedEncoded,
            addEncoded,
            true // _isGenesisUpgrade
        );
    }

    function testForceDeployment_GenesisVsNonGenesis_DifferentBehavior() public {
        FixedForceDeploymentsData memory fixedData = _createFixedData();
        fixedData.beaconDeployerInfo = abi.encode(bytes32(keccak256("beaconDeployer")), uint32(6000), bytes32(keccak256("observable_beaconDeployer")));
        
        ZKChainSpecificForceDeploymentsData memory addData = _createAdditionalData();

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory addEncoded = abi.encode(addData);

        // Test Genesis: should call initL2
        vm.expectCall(L2_MESSAGE_ROOT_ADDR, abi.encodeWithSelector(L2MessageRoot.initL2.selector));
        vm.expectCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.initL2.selector));
        
        // Should NOT call updateL2 for genesis
        vm.expectCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.updateL2.selector), 0);

        vm.mockCall(L2_MESSAGE_ROOT_ADDR, abi.encodeWithSelector(L2MessageRoot.initL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.initL2.selector), "");
        vm.mockCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(L2AssetRouter.initL2.selector), "");
        vm.mockCall(L2_CHAIN_ASSET_HANDLER_ADDR, abi.encodeWithSelector(L2ChainAssetHandler.initL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.setAddresses.selector), "");
        vm.mockCall(
            L2_NTV_BEACON_DEPLOYER_ADDR,
            abi.encodeWithSelector(UpgradeableBeaconDeployer.deployUpgradeableBeacon.selector),
            abi.encode(upgradeableBeacon)
        );
        vm.mockCall(
            L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
            abi.encodeWithSelector(IL2WrappedBaseToken.initializeV3.selector),
            ""
        );
        vm.mockCall(L2_NATIVE_TOKEN_VAULT_ADDR, abi.encodeWithSelector(L2NativeTokenVault.initL2.selector), "");

        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            true, // _isZKsyncOS
            ctmDeployer,
            fixedEncoded,
            addEncoded,
            true // _isGenesisUpgrade
        );
    }
}
