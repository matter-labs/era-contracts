// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {L2GenesisUpgrade} from "contracts/l2-upgrades/L2GenesisUpgrade.sol";
import {FixedForceDeploymentsData, IL2GenesisUpgrade, ZKChainSpecificForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_GENESIS_UPGRADE_ADDR, L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR, L2_NTV_BEACON_DEPLOYER_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_WRAPPED_BASE_TOKEN_IMPL_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Utils} from "deploy-scripts/Utils.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2WrappedBaseToken} from "contracts/bridge/L2WrappedBaseToken.sol";
import {L2MessageRoot} from "contracts/bridgehub/L2MessageRoot.sol";
import {L2Bridgehub} from "contracts/bridgehub/L2Bridgehub.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2ChainAssetHandler} from "contracts/bridgehub/L2ChainAssetHandler.sol";
import {UpgradeableBeaconDeployer} from "contracts/bridge/ntv/UpgradeableBeaconDeployer.sol";
import {SharedL2ContractDeployer} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {SharedL2ContractL2Deployer} from "./_SharedL2ContractL2Deployer.sol";
import {SystemContractsArgs} from "./L2Utils.sol";
import {ISystemContext} from "contracts/state-transition/l2-deps/ISystemContext.sol";

import {Create2FactoryUtils} from "deploy-scripts/Create2FactoryUtils.s.sol";

contract L2GenesisUpgradeTest is Test, SharedL2ContractDeployer, SharedL2ContractL2Deployer {
    uint256 constant CHAIN_ID = 270;
    address ctmDeployerAddress = makeAddr("ctmDeployer");
    address bridgehubOwnerAddress = makeAddr("bridgehubOwner");

    bytes fixedForceDeploymentsData;
    bytes additionalForceDeploymentsData;

    function test() internal virtual override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {}

    function initSystemContracts(
        SystemContractsArgs memory _args
    ) internal override(SharedL2ContractDeployer, SharedL2ContractL2Deployer) {
        super.initSystemContracts(_args);
    }

    function deployViaCreate2(
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal override(Create2FactoryUtils, SharedL2ContractL2Deployer) returns (address) {
        return super.deployViaCreate2(creationCode, constructorArgs);
    }

    function deployL2Contracts(
        uint256 _l1ChainId
    ) public override(SharedL2ContractL2Deployer, SharedL2ContractDeployer) {
        super.deployL2Contracts(_l1ChainId);
    }

    function setUp() public override {
        super.setUp();

        // Deploy and etch L2ComplexUpgrader
        bytes memory complexUpgraderCode = Utils.readZKFoundryBytecodeL1("L2ComplexUpgrader.sol", "L2ComplexUpgrader");
        vm.etch(L2_COMPLEX_UPGRADER_ADDR, complexUpgraderCode);

        // Deploy and etch L2GenesisUpgrade
        bytes memory genesisUpgradeCode = Utils.readZKFoundryBytecodeL1("L2GenesisUpgrade.sol", "L2GenesisUpgrade");
        vm.etch(L2_GENESIS_UPGRADE_ADDR, genesisUpgradeCode);

        // Deploy and etch SystemContext
        bytes memory systemContextCode = Utils.readZKFoundryBytecodeSystemContracts(
            "SystemContext.sol",
            "SystemContext"
        );
        vm.etch(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, systemContextCode);

        // Deploy and etch L2WrappedBaseToken
        bytes memory wrappedBaseTokenCode = Utils.readZKFoundryBytecodeL1(
            "L2WrappedBaseToken.sol",
            "L2WrappedBaseToken"
        );
        vm.etch(L2_WRAPPED_BASE_TOKEN_IMPL_ADDR, wrappedBaseTokenCode);

        // Deploy and etch UpgradeableBeaconDeployer
        new UpgradeableBeaconDeployer();
        bytes memory upgradeableBeaconDeployerCode = Utils.readZKFoundryBytecodeL1(
            "UpgradeableBeaconDeployer.sol",
            "UpgradeableBeaconDeployer"
        );
        vm.etch(L2_NTV_BEACON_DEPLOYER_ADDR, upgradeableBeaconDeployerCode);

        additionalForceDeploymentsData = abi.encode(
            ZKChainSpecificForceDeploymentsData({
                baseTokenAssetId: bytes32(0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70),
                l2LegacySharedBridge: address(0),
                predeployedL2WethAddress: address(1),
                baseTokenL1Address: address(1),
                baseTokenName: "Ether",
                baseTokenSymbol: "ETH"
            })
        );

        bytes memory messageRootBytecode = Utils.readZKFoundryBytecodeL1("L2MessageRoot.sol", "L2MessageRoot");
        bytes memory messageRootBytecodeInfo = abi.encode(L2ContractHelper.hashL2Bytecode(messageRootBytecode));

        bytes memory l2NativeTokenVaultBytecode = Utils.readZKFoundryBytecodeL1(
            "L2NativeTokenVault.sol",
            "L2NativeTokenVault"
        );
        bytes memory l2NtvBytecodeInfo = abi.encode(L2ContractHelper.hashL2Bytecode(l2NativeTokenVaultBytecode));

        bytes memory l2AssetRouterBytecode = Utils.readZKFoundryBytecodeL1("L2AssetRouter.sol", "L2AssetRouter");
        bytes memory l2AssetRouterBytecodeInfo = abi.encode(L2ContractHelper.hashL2Bytecode(l2AssetRouterBytecode));

        bytes memory bridgehubBytecode = Utils.readZKFoundryBytecodeL1("L2Bridgehub.sol", "L2Bridgehub");
        bytes memory bridgehubBytecodeInfo = abi.encode(L2ContractHelper.hashL2Bytecode(bridgehubBytecode));

        bytes memory chainAssetHandlerBytecode = Utils.readZKFoundryBytecodeL1(
            "L2ChainAssetHandler.sol",
            "L2ChainAssetHandler"
        );
        bytes memory chainAssetHandlerBytecodeInfo = abi.encode(
            L2ContractHelper.hashL2Bytecode(chainAssetHandlerBytecode)
        );

        bytes memory beaconDeployerBytecode = Utils.readZKFoundryBytecodeL1(
            "UpgradeableBeaconDeployer.sol",
            "UpgradeableBeaconDeployer"
        );
        bytes memory beaconDeployerBytecodeInfo = abi.encode(L2ContractHelper.hashL2Bytecode(beaconDeployerBytecode));

        fixedForceDeploymentsData = abi.encode(
            FixedForceDeploymentsData({
                l1ChainId: 1,
                eraChainId: CHAIN_ID,
                l1AssetRouter: address(1),
                l2TokenProxyBytecodeHash: bytes32(0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70),
                aliasedL1Governance: address(1),
                maxNumberOfZKChains: 100,
                bridgehubBytecodeInfo: bridgehubBytecodeInfo,
                l2AssetRouterBytecodeInfo: l2AssetRouterBytecodeInfo,
                l2NtvBytecodeInfo: l2NtvBytecodeInfo,
                messageRootBytecodeInfo: messageRootBytecodeInfo,
                chainAssetHandlerBytecodeInfo: chainAssetHandlerBytecodeInfo,
                beaconDeployerInfo: beaconDeployerBytecodeInfo,
                // For genesis upgrade these values will always be zero
                l2SharedBridgeLegacyImpl: address(0),
                l2BridgedStandardERC20Impl: address(0),
                dangerousTestOnlyForcedBeacon: address(0)
            })
        );

        vm.mockCall(
            L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(ISystemContext.setChainId.selector),
            ""
        );
        vm.mockCall(L2_BRIDGEHUB_ADDR, abi.encodeWithSelector(L2Bridgehub.initL2.selector), "");
        vm.mockCall(L2_ASSET_ROUTER_ADDR, abi.encodeWithSelector(L2AssetRouter.initL2.selector), "");
        vm.mockCall(L2_CHAIN_ASSET_HANDLER_ADDR, abi.encodeWithSelector(L2ChainAssetHandler.initL2.selector), "");
        vm.mockCall(
            L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(bytes4(keccak256("getMarker(bytes32)"))),
            abi.encode(1)
        );
    }

    function test_SuccessfulGenesisUpgrade() public {
        bytes memory genesisUpgradeCalldata = abi.encodeWithSelector(
            IL2GenesisUpgrade.genesisUpgrade.selector,
            false, // _isZKsyncOS
            CHAIN_ID,
            ctmDeployerAddress,
            fixedForceDeploymentsData,
            additionalForceDeploymentsData
        );

        vm.expectEmit(true, false, false, true, L2_COMPLEX_UPGRADER_ADDR);
        emit IL2GenesisUpgrade.UpgradeComplete(CHAIN_ID);

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(L2_GENESIS_UPGRADE_ADDR, genesisUpgradeCalldata);
    }
}
