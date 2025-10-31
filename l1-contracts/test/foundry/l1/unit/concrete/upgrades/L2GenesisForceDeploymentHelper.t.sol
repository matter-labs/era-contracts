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

contract MockZKOSContractDeployer {
    mapping(address => bytes32) public deployedBytecodes;

    function setBytecodeDetailsEVM(
        address _addr,
        bytes32 _bytecodeHash,
        uint32 _bytecodeLength,
        bytes32 _observableBytecodeHash
    ) external {
        deployedBytecodes[_addr] = _bytecodeHash;
    }
}

contract MockBaseToken {}

contract L2GenesisForceDeploymentsInitTest is Test {
    using L2GenesisForceDeploymentsHelper for *;

    // Fake deployer address for CTM
    address ctmDeployer = makeAddr("ctmDeployer");

    MockZKOSContractDeployer deployer;

    MockBaseToken mockBaseToken;

    function setUp() public {
        MockZKOSContractDeployer mock = new MockZKOSContractDeployer();
        vm.etch(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, address(mock).code);
        deployer = MockZKOSContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR);

        mockBaseToken = new MockBaseToken();
        vm.etch(L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, address(mockBaseToken).code);
    }

    function testForceDeployment_zkos_Genesis() public {
        FixedForceDeploymentsData memory fixedData;
        fixedData.l1ChainId = 111;
        fixedData.eraChainId = 222;
        fixedData.aliasedL1Governance = makeAddr("aliasedL1Governance");
        fixedData.maxNumberOfZKChains = 5;
        fixedData.l1AssetRouter = makeAddr("l1AssetRouter");
        fixedData.messageRootBytecodeInfo = abi.encode(bytes32(keccak256("messageroot")), bytes32(0), bytes32(0));
        fixedData.bridgehubBytecodeInfo = abi.encode(bytes32(keccak256("bridgehub")), bytes32(0), bytes32(0));
        fixedData.l2AssetRouterBytecodeInfo = abi.encode(bytes32(keccak256("assetRouter")), bytes32(0), bytes32(0));
        fixedData.l2NtvBytecodeInfo = abi.encode(bytes32(keccak256("ntv")), bytes32(0), bytes32(0));
        fixedData.chainAssetHandlerBytecodeInfo = abi.encode(
            bytes32(keccak256("chainHandler")),
            bytes32(0),
            bytes32(0)
        );
        fixedData.beaconDeployerInfo = abi.encode(bytes32(keccak256("beaconDeployer")), bytes32(0), bytes32(0));

        // === Prepare additional data ===
        ZKChainSpecificForceDeploymentsData memory addData;
        addData.baseTokenAssetId = keccak256("baseTokenAsset");
        addData.baseTokenL1Address = makeAddr("baseTokenL1Address");
        addData.baseTokenName = "Ether";
        addData.baseTokenSymbol = "ETH";

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory addEncoded = abi.encode(addData);

        vm.mockCall(L2_MESSAGE_ROOT_ADDR, abi.encodeWithSelector(L2MessageRoot.initL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.initL2.selector), "");
        vm.mockCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(L2AssetRouter.initL2.selector), "");

        vm.mockCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(L2NativeTokenVault.updateL2.selector), "");
        vm.mockCall(L2_CHAIN_ASSET_HANDLER_ADDR, abi.encodeWithSelector(L2ChainAssetHandler.updateL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.setAddresses.selector), "");

        vm.mockCall(L2_NATIVE_TOKEN_VAULT_ADDR, abi.encodeWithSelector(L2NativeTokenVault.updateL2.selector), "");

        vm.mockCall(
            L2_NTV_BEACON_DEPLOYER_ADDR,
            abi.encodeWithSelector(UpgradeableBeaconDeployer.deployUpgradeableBeacon.selector),
            abi.encode(makeAddr("upgradeableBeacon"))
        );

        // Check that final addresses match.
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

        vm.mockCall(
            L2_WRAPPED_BASE_TOKEN_IMPL_ADDR,
            abi.encodeWithSelector(IL2WrappedBaseToken.initializeV3.selector),
            ""
        );

        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            true, // _isZKsyncOS
            ctmDeployer,
            fixedEncoded,
            addEncoded,
            true // _isGenesisUpgrade
        );

        assertEq(deployer.deployedBytecodes(L2_MESSAGE_ROOT_ADDR), keccak256("messageroot"));
        assertEq(deployer.deployedBytecodes(L2_BRIDGEHUB_ADDR), keccak256("bridgehub"));
        assertEq(deployer.deployedBytecodes(L2_ASSET_ROUTER_ADDR), keccak256("assetRouter"));
        assertEq(deployer.deployedBytecodes(L2_NATIVE_TOKEN_VAULT_ADDR), keccak256("ntv"));
        assertEq(deployer.deployedBytecodes(L2_CHAIN_ASSET_HANDLER_ADDR), keccak256("chainHandler"));
        assertEq(deployer.deployedBytecodes(L2_NTV_BEACON_DEPLOYER_ADDR), keccak256("beaconDeployer"));
    }

    function testForceDeployment_zkos_NotGenesis() public {
        FixedForceDeploymentsData memory fixedData;
        fixedData.l1ChainId = 111;
        fixedData.eraChainId = 222;
        fixedData.aliasedL1Governance = makeAddr("aliasedL1Governance");
        fixedData.maxNumberOfZKChains = 5;
        fixedData.l1AssetRouter = makeAddr("l1AssetRouter");
        fixedData.messageRootBytecodeInfo = abi.encode(bytes32(keccak256("messageroot")), bytes32(0), bytes32(0));
        fixedData.bridgehubBytecodeInfo = abi.encode(bytes32(keccak256("bridgehub")), bytes32(0), bytes32(0));
        fixedData.l2AssetRouterBytecodeInfo = abi.encode(bytes32(keccak256("assetRouter")), bytes32(0), bytes32(0));
        fixedData.l2NtvBytecodeInfo = abi.encode(bytes32(keccak256("ntv")), bytes32(0), bytes32(0));
        fixedData.chainAssetHandlerBytecodeInfo = abi.encode(
            bytes32(keccak256("chainHandler")),
            bytes32(0),
            bytes32(0)
        );
        // Not used for non-genesis upgrade.
        fixedData.beaconDeployerInfo = "";

        // === Prepare additional data ===
        ZKChainSpecificForceDeploymentsData memory addData;
        addData.baseTokenAssetId = keccak256("baseTokenAsset");
        addData.baseTokenL1Address = makeAddr("baseTokenL1Address");
        addData.baseTokenName = "Ether";
        addData.baseTokenSymbol = "ETH";

        bytes memory fixedEncoded = abi.encode(fixedData);
        bytes memory addEncoded = abi.encode(addData);

        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.updateL2.selector), "");
        vm.mockCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(L2AssetRouter.updateL2.selector), "");
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(bytes4(keccak256("L2_LEGACY_SHARED_BRIDGE()"))),
            abi.encode(address(0))
        );
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(bytes4(keccak256("WETH_TOKEN()"))),
            abi.encode(makeAddr("wethToken"))
        );
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(bytes4(keccak256("L2_TOKEN_PROXY_BYTECODE_HASH()"))),
            abi.encode(address(0))
        );
        vm.mockCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(L2NativeTokenVault.updateL2.selector), "");
        vm.mockCall(L2_CHAIN_ASSET_HANDLER_ADDR, abi.encodeWithSelector(L2ChainAssetHandler.updateL2.selector), "");
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.setAddresses.selector), "");
        // Check that final addresses match.
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

        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            true, // _isZKsyncOS
            ctmDeployer,
            fixedEncoded,
            addEncoded,
            false // _isGenesisUpgrade
        );

        assertEq(deployer.deployedBytecodes(L2_MESSAGE_ROOT_ADDR), keccak256("messageroot"));
        assertEq(deployer.deployedBytecodes(L2_BRIDGEHUB_ADDR), keccak256("bridgehub"));
        assertEq(deployer.deployedBytecodes(L2_ASSET_ROUTER_ADDR), keccak256("assetRouter"));
        assertEq(deployer.deployedBytecodes(L2_NATIVE_TOKEN_VAULT_ADDR), keccak256("ntv"));
        assertEq(deployer.deployedBytecodes(L2_CHAIN_ASSET_HANDLER_ADDR), keccak256("chainHandler"));
    }
}
